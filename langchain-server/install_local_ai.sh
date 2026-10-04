#!/usr/bin/env bash
# Install a local AI stack (Ollama + the QHF LangServe API) next to an existing n8n, without touching n8n:
# no n8n restart, no change to n8n's containers, config or firewall. AI gets hard CPU and RAM caps so n8n keeps
# headroom, listens only on the server itself (and n8n's Docker network), and is reachable from any n8n workflow.
#
#   bash install_local_ai.sh                 # auto: Docker if available, otherwise native systemd services
#   MODE=native bash install_local_ai.sh     # force native services (no Docker)
#
# Safe to re-run: keeps the API key and downloaded models, re-sizes the limits and updates the code.
# Optional overrides: TEXT_BASE_MODEL, VISION_BASE_MODEL, AI_CPUS, AI_MEM_MB, OLLAMA_PORT, LANGCHAIN_PORT,
# N8N_NETWORK (Docker network to join), APP_DIR (default /opt/qhf-ai), SKIP_SMOKE_TEST=1.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${APP_DIR:-/opt/qhf-ai}"
MODE="${MODE:-auto}"
NUM_CTX="${NUM_CTX:-8192}"
KEEP_ALIVE="${KEEP_ALIVE:-10m}"

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || die "Run as root or install sudo."
  SUDO=(sudo)
fi
command -v curl >/dev/null || die "curl is required (sudo apt-get install -y curl)."
[ -f "$SRC_DIR/app/server.py" ] || die "Run this script from the langchain-server folder of the repo."

# Value of KEY in an existing .env (empty if the file or key is missing).
env_get() {
  [ -f "$APP_DIR/.env" ] || return 0
  "${SUDO[@]}" sed -n "s/^$1=//p" "$APP_DIR/.env" | tail -n 1
}
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
pick_port() {
  local p=$1
  while port_busy "$p"; do p=$((p + 1)); done
  echo "$p"
}

# ---------------------------------------------------------------- sizing
log "Sizing the AI limits for this server"
CPUS_TOTAL=$(nproc)
MEM_TOTAL_MB=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
# n8n and the OS keep at least 3 GB or 30% of RAM (whichever is larger) and at least one CPU core.
RESERVE_MB=$((MEM_TOTAL_MB * 30 / 100))
if [ "$RESERVE_MB" -lt 3072 ]; then RESERVE_MB=3072; fi
AI_MEM_MB="${AI_MEM_MB:-$((MEM_TOTAL_MB - RESERVE_MB))}"
if [ -z "${AI_CPUS:-}" ]; then
  if [ "$CPUS_TOTAL" -gt 1 ]; then AI_CPUS=$((CPUS_TOTAL - 1)); else AI_CPUS=1; fi
fi
[[ "$AI_CPUS" =~ ^[1-9][0-9]*$ ]] && [ "$AI_CPUS" -le "$CPUS_TOTAL" ] ||
  die "AI_CPUS must be a whole number between 1 and $CPUS_TOTAL."
[[ "$AI_MEM_MB" =~ ^[0-9]+$ ]] && [ "$AI_MEM_MB" -ge 5000 ] ||
  die "Only ${MEM_TOTAL_MB} MB RAM: local models need about 8 GB in total so that n8n keeps 3 GB."
if [ "$CPUS_TOTAL" -eq 1 ]; then warn "1 CPU core: n8n and the AI will share it (AI has lower priority)."; fi

if [ "$AI_MEM_MB" -ge 12000 ]; then MAX_LOADED=2; else MAX_LOADED=1; fi
if [ "$AI_MEM_MB" -ge 7000 ]; then DEFAULT_TEXT=llama3.1:8b; else DEFAULT_TEXT=llama3.2:3b; fi
TEXT_BASE_MODEL="${TEXT_BASE_MODEL:-$DEFAULT_TEXT}"
VISION_BASE_MODEL="${VISION_BASE_MODEL:-gemma3:4b}"
NUM_THREAD="$AI_CPUS"
echo "Server: $CPUS_TOTAL CPU cores, $MEM_TOTAL_MB MB RAM."
echo "AI limit: $AI_CPUS cores, $AI_MEM_MB MB RAM (n8n and the OS keep the rest)."
echo "Models: $TEXT_BASE_MODEL (text), $VISION_BASE_MODEL (charts); $MAX_LOADED loaded at a time."

# ---------------------------------------------------------------- mode
DOCKER=()
if [ "$MODE" != native ] && command -v docker >/dev/null; then
  if "${SUDO[@]}" docker info >/dev/null 2>&1; then DOCKER=("${SUDO[@]}" docker); fi
fi
if [ "$MODE" = auto ]; then
  if [ ${#DOCKER[@]} -gt 0 ]; then MODE=docker; else MODE=native; fi
fi
case "$MODE" in
  docker) [ ${#DOCKER[@]} -gt 0 ] || die "MODE=docker but the Docker daemon is not reachable." ;;
  native) ;;
  *) die "MODE must be auto, docker or native." ;;
esac
echo "Install mode: $MODE"

disk_free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 {print int($4 / 1048576)}'; }
# Models take about 9 GB; the Ollama Docker image adds up to 9 GB more on x86 servers.
if [ "$MODE" = docker ]; then
  MODEL_DISK="$("${DOCKER[@]}" info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  NEED_GB=20
  if "${DOCKER[@]}" image inspect "${OLLAMA_IMAGE:-ollama/ollama:latest}" >/dev/null 2>&1; then NEED_GB=12; fi
else
  MODEL_DISK=/usr/share
  NEED_GB=12
fi
FREE_GB="$(disk_free_gb "$MODEL_DISK")"
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt "$NEED_GB" ]; then
  die "Only ${FREE_GB} GB free on $MODEL_DISK; the AI stack needs about ${NEED_GB} GB."
fi

# ---------------------------------------------------------------- ports
# Re-runs keep the ports already in use by this stack; fresh installs skip ports another program uses.
OURS_RUNNING=0
if [ "$MODE" = docker ] && "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qx qhf-ollama; then OURS_RUNNING=1; fi
if [ "$MODE" = native ] && systemctl is-enabled qhf-langchain >/dev/null 2>&1; then OURS_RUNNING=1; fi
if [ "$OURS_RUNNING" = 1 ]; then
  OLLAMA_PORT="${OLLAMA_PORT:-$(env_get OLLAMA_PORT)}"
  LANGCHAIN_PORT="${LANGCHAIN_PORT:-$(env_get LANGCHAIN_PORT)}"
fi
if [ -z "${OLLAMA_PORT:-}" ]; then
  if [ "$MODE" = native ] && command -v ollama >/dev/null; then
    OLLAMA_PORT=11434 # the existing Ollama service is reconfigured in place
  else
    OLLAMA_PORT="$(pick_port 11434)"
  fi
fi
LANGCHAIN_PORT="${LANGCHAIN_PORT:-$(pick_port 8000)}"

# ---------------------------------------------------------------- files
log "Writing $APP_DIR"
API_KEY="$(env_get QHF_API_KEY)"
if [ ${#API_KEY} -lt 24 ]; then API_KEY="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"; fi
if [ "$MODE" = docker ]; then OLLAMA_URL_FOR_APP="http://qhf-ollama:11434"; else OLLAMA_URL_FOR_APP="http://127.0.0.1:$OLLAMA_PORT"; fi

"${SUDO[@]}" install -d -m 755 "$APP_DIR" "$APP_DIR/app" "$APP_DIR/modelfiles"
"${SUDO[@]}" install -m 644 "$SRC_DIR/app/server.py" "$SRC_DIR/app/requirements.txt" \
  "$SRC_DIR/app/Dockerfile" "$SRC_DIR/app/.dockerignore" "$APP_DIR/app/"
"${SUDO[@]}" install -m 644 "$SRC_DIR/docker-compose.yml" "$APP_DIR/"
for kind in text vision; do
  if [ "$kind" = text ]; then base="$TEXT_BASE_MODEL"; else base="$VISION_BASE_MODEL"; fi
  printf 'FROM %s\nPARAMETER num_thread %s\nPARAMETER num_ctx %s\n' "$base" "$NUM_THREAD" "$NUM_CTX" |
    "${SUDO[@]}" tee "$APP_DIR/modelfiles/qhf-$kind.Modelfile" >/dev/null
done

"${SUDO[@]}" tee "$APP_DIR/.env" >/dev/null <<EOF
# Written by install_local_ai.sh. Re-run the installer to change sizes or models; it keeps QHF_API_KEY.
QHF_API_KEY=$API_KEY
TEXT_BASE_MODEL=$TEXT_BASE_MODEL
VISION_BASE_MODEL=$VISION_BASE_MODEL
TEXT_MODEL=qhf-text
VISION_MODEL=qhf-vision
NUM_CTX=$NUM_CTX
NUM_THREAD=$NUM_THREAD
TEMPERATURE=0.3
KEEP_ALIVE=$KEEP_ALIVE
OLLAMA_BASE_URL=$OLLAMA_URL_FOR_APP
OLLAMA_CPUS=$AI_CPUS
OLLAMA_MEM_MB=$AI_MEM_MB
OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED
OLLAMA_PORT=$OLLAMA_PORT
LANGCHAIN_PORT=$LANGCHAIN_PORT
EOF
"${SUDO[@]}" chmod 600 "$APP_DIR/.env"

# ---------------------------------------------------------------- docker mode
N8N_NETS=()
N8N_CONTAINERS=()
N8N_ON_DEFAULT_BRIDGE=0
N8N_ON_HOST_NET=0
GATEWAY=""

install_docker_stack() {
  COMPOSE=("${DOCKER[@]}" compose)
  "${COMPOSE[@]}" version >/dev/null 2>&1 ||
    die "Docker Compose v2 is missing. Install it (Ubuntu: sudo apt-get install -y docker-compose-plugin, or docker-compose-v2) and re-run."

  log "Looking for the running n8n containers (read-only)"
  local c net
  mapfile -t N8N_CONTAINERS < <("${DOCKER[@]}" ps --format '{{.Names}} {{.Image}}' |
    awk 'tolower($0) ~ /n8n/ && $1 !~ /^qhf-/ {print $1}')
  for c in "${N8N_CONTAINERS[@]}"; do
    if [ "$("${DOCKER[@]}" inspect -f '{{.HostConfig.NetworkMode}}' "$c")" = host ]; then
      N8N_ON_HOST_NET=1
      continue
    fi
    for net in $("${DOCKER[@]}" inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c"); do
      case "$net" in
        bridge) N8N_ON_DEFAULT_BRIDGE=1 ;;
        host | none | qhf-ai) ;;
        *) [[ " ${N8N_NETS[*]} " == *" $net "* ]] || N8N_NETS+=("$net") ;;
      esac
    done
  done
  if [ -n "${N8N_NETWORK:-}" ]; then N8N_NETS=("$N8N_NETWORK"); fi
  if [ ${#N8N_CONTAINERS[@]} -gt 0 ]; then
    echo "n8n containers: ${N8N_CONTAINERS[*]}"
  else
    echo "No running n8n container found (n8n may run outside Docker)."
  fi
  if [ ${#N8N_NETS[@]} -gt 0 ]; then echo "Joining n8n's Docker network(s): ${N8N_NETS[*]}"; fi

  # n8n on Docker's default bridge (or not found): also publish on the bridge gateway, which only the
  # server itself and its containers can reach.
  if [ "$N8N_ON_DEFAULT_BRIDGE" = 1 ] || [ ${#N8N_CONTAINERS[@]} -eq 0 ]; then
    GATEWAY="$("${DOCKER[@]}" network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  fi

  local i svc port inner
  {
    echo "# Written by install_local_ai.sh: how n8n reaches the AI stack. Re-run the installer to regenerate."
    if [ ${#N8N_NETS[@]} -eq 0 ] && [ -z "$GATEWAY" ]; then
      echo "services: {}"
    else
      echo "services:"
      for svc in qhf-ollama qhf-langchain; do
        echo "  $svc:"
        if [ ${#N8N_NETS[@]} -gt 0 ]; then
          echo "    networks:"
          echo "      - qhf-ai"
          for i in "${!N8N_NETS[@]}"; do echo "      - n8n-net-$i"; done
        fi
        if [ -n "$GATEWAY" ]; then
          if [ "$svc" = qhf-ollama ]; then port=$OLLAMA_PORT inner=11434; else port=$LANGCHAIN_PORT inner=8000; fi
          echo "    ports:"
          echo "      - \"$GATEWAY:$port:$inner\""
        fi
      done
      if [ ${#N8N_NETS[@]} -gt 0 ]; then
        echo "networks:"
        for i in "${!N8N_NETS[@]}"; do
          printf '  n8n-net-%s:\n    external: true\n    name: %s\n' "$i" "${N8N_NETS[$i]}"
        done
      fi
    fi
  } | "${SUDO[@]}" tee "$APP_DIR/docker-compose.override.yml" >/dev/null

  log "Starting the AI containers (n8n is not touched)"
  COMPOSE+=(--project-directory "$APP_DIR" -f "$APP_DIR/docker-compose.yml" -f "$APP_DIR/docker-compose.override.yml")
  "${COMPOSE[@]}" up -d --build
  OLLAMA_CMD=("${DOCKER[@]}" exec qhf-ollama ollama)
  MODELFILE_DIR=/modelfiles
}

# ---------------------------------------------------------------- native mode
install_native_services() {
  command -v systemctl >/dev/null || die "Native mode needs systemd."
  log "Python 3.10+"
  local py="" c
  for c in python3.12 python3.11 python3.10 python3; do
    if command -v "$c" >/dev/null && "$c" -c 'import sys, ensurepip; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
      py="$c"
      break
    fi
  done
  if [ -z "$py" ]; then
    if command -v apt-get >/dev/null; then
      "${SUDO[@]}" apt-get update -y
      "${SUDO[@]}" apt-get install -y python3 python3-venv
    elif command -v dnf >/dev/null; then
      "${SUDO[@]}" dnf install -y python3.11
    fi
    for c in python3.12 python3.11 python3.10 python3; do
      if command -v "$c" >/dev/null && "$c" -c 'import sys, ensurepip; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
        py="$c"
        break
      fi
    done
  fi
  [ -n "$py" ] || die "Install Python 3.10+ with venv support and re-run."

  log "Ollama"
  if ! command -v ollama >/dev/null; then curl -fsSL https://ollama.com/install.sh | sh; fi
  "${SUDO[@]}" install -d /etc/systemd/system/ollama.service.d
  "${SUDO[@]}" tee /etc/systemd/system/ollama.service.d/10-qhf-limits.conf >/dev/null <<EOF
# Written by install_local_ai.sh: Ollama listens on this server only and is capped so it cannot starve n8n.
[Service]
Environment="OLLAMA_HOST=127.0.0.1:$OLLAMA_PORT"
Environment="OLLAMA_KEEP_ALIVE=$KEEP_ALIVE"
Environment="OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED"
Environment="OLLAMA_NUM_PARALLEL=1"
CPUQuota=$((AI_CPUS * 100))%
MemoryMax=${AI_MEM_MB}M
MemorySwapMax=0
Nice=10
OOMScoreAdjust=500
EOF
  "${SUDO[@]}" systemctl daemon-reload
  "${SUDO[@]}" systemctl enable ollama >/dev/null
  "${SUDO[@]}" systemctl restart ollama

  log "LangServe API"
  id qhf >/dev/null 2>&1 || "${SUDO[@]}" useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin qhf
  "${SUDO[@]}" chown root:qhf "$APP_DIR/.env"
  "${SUDO[@]}" chmod 640 "$APP_DIR/.env"
  "${SUDO[@]}" "$py" -m venv "$APP_DIR/venv"
  "${SUDO[@]}" "$APP_DIR/venv/bin/pip" install -q --upgrade pip
  "${SUDO[@]}" "$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/app/requirements.txt"
  "${SUDO[@]}" tee /etc/systemd/system/qhf-langchain.service >/dev/null <<EOF
[Unit]
Description=QHF LangServe API (local AI for n8n)
After=network-online.target ollama.service
Wants=ollama.service

[Service]
User=qhf
Group=qhf
WorkingDirectory=$APP_DIR/app
EnvironmentFile=$APP_DIR/.env
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=$APP_DIR/venv/bin/uvicorn server:app --host 127.0.0.1 --port $LANGCHAIN_PORT --timeout-keep-alive 600
Restart=always
RestartSec=5
CPUQuota=50%
MemoryMax=768M
Nice=10
OOMScoreAdjust=500
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
  "${SUDO[@]}" systemctl daemon-reload
  "${SUDO[@]}" systemctl enable qhf-langchain >/dev/null
  "${SUDO[@]}" systemctl restart qhf-langchain

  local i
  for i in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$OLLAMA_PORT/api/version" >/dev/null 2>&1 && break
    sleep 2
  done
  OLLAMA_CMD=(env "OLLAMA_HOST=127.0.0.1:$OLLAMA_PORT" ollama)
  MODELFILE_DIR="$APP_DIR/modelfiles"
}

if [ "$MODE" = docker ]; then install_docker_stack; else install_native_services; fi

# ---------------------------------------------------------------- models
log "Downloading $TEXT_BASE_MODEL and $VISION_BASE_MODEL (several GB on the first run)"
"${OLLAMA_CMD[@]}" pull "$TEXT_BASE_MODEL"
"${OLLAMA_CMD[@]}" pull "$VISION_BASE_MODEL"
log "Creating qhf-text and qhf-vision ($NUM_THREAD threads, $NUM_CTX-token context)"
"${OLLAMA_CMD[@]}" create qhf-text -f "$MODELFILE_DIR/qhf-text.Modelfile"
"${OLLAMA_CMD[@]}" create qhf-vision -f "$MODELFILE_DIR/qhf-vision.Modelfile"

# ---------------------------------------------------------------- checks
log "Health check"
HEALTH=""
for _ in $(seq 1 30); do
  if HEALTH="$(curl -fsS "http://127.0.0.1:$LANGCHAIN_PORT/health" 2>/dev/null)"; then break; fi
  sleep 2
done
[ -n "$HEALTH" ] || die "The LangServe API did not become healthy. Logs: $([ "$MODE" = docker ] && echo 'sudo docker logs qhf-langchain' || echo 'journalctl -u qhf-langchain')"
echo "$HEALTH"

if [ "${SKIP_SMOKE_TEST:-0}" != 1 ]; then
  log "Test question to the text model (the first answer loads the model and can take a minute or two)"
  curl -fsS --max-time 600 -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
    -d '{"input": {"system": "Answer in one short sentence.", "prompt": "Say hello to the Quant Hedgefund bot."}}' \
    "http://127.0.0.1:$LANGCHAIN_PORT/analyst/invoke" | cut -c1-300 || warn "The test question failed; check the logs."
  echo
fi

# How n8n reaches the stack.
if [ "$MODE" = docker ] && [ ${#N8N_NETS[@]} -gt 0 ]; then
  OLLAMA_URL="http://qhf-ollama:11434"
  LANGCHAIN_URL="http://qhf-langchain:8000"
elif [ "$MODE" = docker ] && [ "$N8N_ON_DEFAULT_BRIDGE" = 1 ] && [ -n "$GATEWAY" ]; then
  OLLAMA_URL="http://$GATEWAY:$OLLAMA_PORT"
  LANGCHAIN_URL="http://$GATEWAY:$LANGCHAIN_PORT"
else
  OLLAMA_URL="http://127.0.0.1:$OLLAMA_PORT"
  LANGCHAIN_URL="http://127.0.0.1:$LANGCHAIN_PORT"
fi

if [ "$MODE" = docker ] && [ ${#N8N_CONTAINERS[@]} -gt 0 ] && [ "$N8N_ON_HOST_NET" = 0 ]; then
  log "Checking that n8n can reach the AI (read-only request from ${N8N_CONTAINERS[0]})"
  if "${DOCKER[@]}" exec "${N8N_CONTAINERS[0]}" node -e \
    "fetch('$LANGCHAIN_URL/health').then(r => r.text()).then(t => console.log(t)).catch(e => { console.error(e.message); process.exit(1); })"; then
    echo "n8n can reach the AI stack."
  else
    warn "n8n could not reach $LANGCHAIN_URL. Set N8N_NETWORK=<n8n's docker network> and re-run."
  fi
fi

cat <<EOF

========================================================================
Local AI is running. Use these settings in n8n:

1) Any workflow (built-in Ollama nodes, e.g. AI Agent + "Ollama Chat Model"):
     Credential type: Ollama     Base URL: $OLLAMA_URL
     Models: qhf-text (text), qhf-vision (images)

2) Quant Hedgefund workflow, node "Ask LangChain Analyst":
     URL: $LANGCHAIN_URL/analyst/invoke
     Header Auth credential "QHF LangChain API key":
       Name:  X-API-Key
       Value: $API_KEY
     (stored in $APP_DIR/.env)

Limits: $AI_CPUS of $CPUS_TOTAL CPU cores, $AI_MEM_MB of $MEM_TOTAL_MB MB RAM. Nothing is exposed to the internet.
Remove everything: bash uninstall_local_ai.sh   (add --purge to also delete the models)
========================================================================
EOF

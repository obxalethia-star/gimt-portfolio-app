#!/usr/bin/env bash
# Install Ollama + the QHF LangServe API on an Oracle Cloud VM (Ubuntu 22.04/24.04 or Oracle Linux 9).
# Usage, from this folder on the VM:  bash setup_oracle_vm.sh
# Re-running is safe: it keeps the existing .env (and API key) and only updates code and models.
set -euo pipefail

APP_DIR=/opt/qhf-langchain
PORT="${PORT:-8000}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> System packages"
if command -v apt-get >/dev/null; then
  sudo apt-get update -y
  sudo apt-get install -y python3 python3-venv python3-pip curl openssl
  PY=python3
elif command -v dnf >/dev/null; then
  sudo dnf install -y python3.11 python3.11-pip curl openssl
  PY=python3.11
else
  echo "Unsupported distro: install Python 3.10+ manually." >&2
  exit 1
fi
"$PY" -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required"'

echo "==> Ollama"
if ! command -v ollama >/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
sudo systemctl enable --now ollama

echo "==> App files in $APP_DIR"
sudo mkdir -p "$APP_DIR"
sudo cp "$SRC_DIR/server.py" "$SRC_DIR/requirements.txt" "$APP_DIR/"
sudo chown -R "$USER":"$USER" "$APP_DIR"
"$PY" -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --upgrade pip -q
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q

if [ ! -f "$APP_DIR/.env" ]; then
  cp "$SRC_DIR/.env.example" "$APP_DIR/.env"
  KEY="$(openssl rand -hex 32)"
  sed -i "s/^QHF_API_KEY=.*/QHF_API_KEY=$KEY/" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  echo
  echo "Generated API key (put it in the n8n 'QHF LangChain API key' credential as the X-API-Key value):"
  echo "    $KEY"
  echo
fi

# shellcheck disable=SC1091
set -a; . "$APP_DIR/.env"; set +a
echo "==> Pulling models: $TEXT_MODEL and $VISION_MODEL (several GB, first run takes a while)"
ollama pull "$TEXT_MODEL"
ollama pull "$VISION_MODEL"

echo "==> systemd service"
sudo tee /etc/systemd/system/qhf-langchain.service >/dev/null <<UNIT
[Unit]
Description=QHF LangServe API
After=network-online.target ollama.service
Wants=ollama.service

[Service]
User=$USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/.venv/bin/uvicorn server:app --host 0.0.0.0 --port $PORT --timeout-keep-alive 600
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now qhf-langchain
sudo systemctl restart qhf-langchain

echo "==> Host firewall: allow TCP $PORT"
if command -v firewall-cmd >/dev/null && sudo firewall-cmd --state >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --add-port="$PORT"/tcp
  sudo firewall-cmd --reload
elif command -v iptables >/dev/null; then
  # Oracle's Ubuntu images end the INPUT chain with a REJECT rule, so insert at the top.
  if ! sudo iptables -C INPUT -p tcp --dport "$PORT" -m state --state NEW -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT -p tcp --dport "$PORT" -m state --state NEW -j ACCEPT
  fi
  if command -v netfilter-persistent >/dev/null; then sudo netfilter-persistent save; fi
fi

sleep 3
echo "==> Health check"
curl -fsS "http://127.0.0.1:$PORT/health" && echo
echo
echo "Done. Remaining manual step: in the OCI console add an ingress rule for TCP $PORT"
echo "(Networking > Virtual cloud networks > your VCN > Security Lists > Default > Add Ingress Rules)."
echo "Then test from your PC:  curl http://<public-ip>:$PORT/health"

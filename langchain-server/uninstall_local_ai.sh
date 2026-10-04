#!/usr/bin/env bash
# Remove the local AI stack installed by install_local_ai.sh. n8n is not touched.
#   bash uninstall_local_ai.sh           # remove the services, keep the downloaded models
#   bash uninstall_local_ai.sh --purge   # also delete the models
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/qhf-ai}"
PURGE=0
if [ "${1:-}" = --purge ]; then PURGE=1; fi
SUDO=()
if [ "$(id -u)" -ne 0 ]; then SUDO=(sudo); fi

if command -v docker >/dev/null && "${SUDO[@]}" docker info >/dev/null 2>&1; then
  echo "==> Docker containers"
  "${SUDO[@]}" docker rm -f qhf-langchain qhf-ollama >/dev/null 2>&1 || true
  "${SUDO[@]}" docker network rm qhf-ai >/dev/null 2>&1 || true
  if [ "$PURGE" = 1 ]; then
    "${SUDO[@]}" docker volume rm qhf-ollama-models >/dev/null 2>&1 || true
    "${SUDO[@]}" docker image rm qhf-langchain:local >/dev/null 2>&1 || true
  fi
fi

if [ -d /run/systemd/system ]; then
  if [ -f /etc/systemd/system/qhf-langchain.service ]; then
    echo "==> qhf-langchain service"
    "${SUDO[@]}" systemctl disable --now qhf-langchain >/dev/null 2>&1 || true
    "${SUDO[@]}" rm -f /etc/systemd/system/qhf-langchain.service
  fi
  if [ -f /etc/systemd/system/ollama.service.d/10-qhf-limits.conf ]; then
    echo "==> Ollama limits"
    "${SUDO[@]}" rm -f /etc/systemd/system/ollama.service.d/10-qhf-limits.conf
    "${SUDO[@]}" systemctl daemon-reload
    if [ "$PURGE" = 1 ] && command -v ollama >/dev/null; then
      ollama rm qhf-text qhf-vision >/dev/null 2>&1 || true
    fi
    "${SUDO[@]}" systemctl restart ollama >/dev/null 2>&1 || true
    echo "Ollama itself is still installed. To remove it too: sudo systemctl disable --now ollama && sudo rm /usr/local/bin/ollama"
  fi
  "${SUDO[@]}" systemctl daemon-reload || true
fi

"${SUDO[@]}" rm -rf "$APP_DIR"
echo "Local AI stack removed$([ "$PURGE" = 1 ] && echo ', including models')."

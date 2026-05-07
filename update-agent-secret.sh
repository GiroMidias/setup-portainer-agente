#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Atualiza o AGENT_SECRET de um Portainer Agent existente.
#
# Uso comum no servidor que ficou Down/unreachable:
#   sudo bash update-agent-secret.sh
#
# Uso com secret direto:
#   sudo bash update-agent-secret.sh --secret "SEU_AGENT_SECRET"
#
# Uso buscando do Portainer principal:
#   sudo bash update-agent-secret.sh --fetch-from root@92.118.59.204
#   sudo bash update-agent-secret.sh --fetch-from root@92.118.59.204 --ssh-key /root/.ssh/id_rsa
# ============================================================

PORTAINER_AGENT_SERVICE_NAME="portainer_agent"
AGENT_SECRET_FILE="/root/portainer-agent-secret.txt"
DEFAULT_AGENT_IMAGE="portainer/agent:2.39.1"
DEFAULT_AGENT_PORT="9001"
DEFAULT_MAIN_SECRET_FILE="/root/portainer-agent-secret.txt"

AGENT_SECRET=""
FETCH_FROM=""
SSH_PORT="22"
SSH_KEY=""
MAIN_SECRET_FILE="$DEFAULT_MAIN_SECRET_FILE"
AGENT_IMAGE=""
AGENT_PORT="$DEFAULT_AGENT_PORT"

ask_required() {
  local prompt="$1"
  local value=""

  while [ -z "$value" ]; do
    printf "%s: " "$prompt" >&2
    read -r value
    [ -n "$value" ] || echo "Campo obrigatorio." >&2
  done

  echo "$value"
}

usage() {
  sed -n '2,18p' "$0"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERRO: execute como root."
    echo "Use: sudo bash $0"
    exit 1
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --secret)
        AGENT_SECRET="${2:-}"
        shift 2
        ;;
      --fetch-from)
        FETCH_FROM="${2:-}"
        shift 2
        ;;
      --ssh-port)
        SSH_PORT="${2:-22}"
        shift 2
        ;;
      --ssh-key)
        SSH_KEY="${2:-}"
        shift 2
        ;;
      --main-secret-file)
        MAIN_SECRET_FILE="${2:-$DEFAULT_MAIN_SECRET_FILE}"
        shift 2
        ;;
      --image)
        AGENT_IMAGE="${2:-}"
        shift 2
        ;;
      --port)
        AGENT_PORT="${2:-$DEFAULT_AGENT_PORT}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERRO: parametro desconhecido: $1"
        usage
        exit 1
        ;;
    esac
  done
}

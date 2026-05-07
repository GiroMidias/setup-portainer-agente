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
#
# O --fetch-from busca o secret direto na stack/servico Portainer do principal.
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

print_header() {
  echo "============================================================"
  echo " Portainer Agent - Atualizar AGENT_SECRET"
  echo "============================================================"
  echo ""
}

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

fetch_secret_from_main() {
  local ssh_target="$1"
  local ssh_cmd=(ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

  if [ -n "$SSH_KEY" ]; then
    ssh_cmd+=(-i "$SSH_KEY")
  fi

  "${ssh_cmd[@]}" "$ssh_target" bash -s -- "$MAIN_SECRET_FILE" <<'REMOTE_SECRET'
set -e

MAIN_SECRET_FILE="$1"

print_secret_from_service() {
  local service="$1"

  docker service inspect "$service" \
    --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= '/^AGENT_SECRET=/{print $2; exit}'
}

print_secret_from_container() {
  local container="$1"

  docker inspect "$container" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= '/^AGENT_SECRET=/{print $2; exit}'
}

if command -v docker >/dev/null 2>&1; then
  SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

  if [ "$SWARM_STATE" = "active" ]; then
    PORTAINER_SERVER_SERVICES="$(docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null \
      | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
      | awk '{print $1}' || true)"

    SECRET="$(for service in $PORTAINER_SERVER_SERVICES; do
      print_secret_from_service "$service"
    done | awk 'NF{print; exit}')"

    if [ -n "$SECRET" ]; then
      echo "$SECRET"
      exit 0
    fi

    PORTAINER_AGENT_SERVICES="$(docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null \
      | grep -E 'portainer/agent' \
      | awk '{print $1}' || true)"

    SECRET="$(for service in $PORTAINER_AGENT_SERVICES; do
      print_secret_from_service "$service"
    done | awk 'NF{print; exit}')"

    if [ -n "$SECRET" ]; then
      echo "$SECRET"
      exit 0
    fi
  fi

  PORTAINER_SERVER_CONTAINERS="$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null \
    | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
    | awk '{print $1}' || true)"

  SECRET="$(for container in $PORTAINER_SERVER_CONTAINERS; do
    print_secret_from_container "$container"
  done | awk 'NF{print; exit}')"

  if [ -n "$SECRET" ]; then
    echo "$SECRET"
    exit 0
  fi

  PORTAINER_AGENT_CONTAINERS="$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null \
    | grep -E 'portainer/agent' \
    | awk '{print $1}' || true)"

  SECRET="$(for container in $PORTAINER_AGENT_CONTAINERS; do
    print_secret_from_container "$container"
  done | awk 'NF{print; exit}')"

  if [ -n "$SECRET" ]; then
    echo "$SECRET"
    exit 0
  fi
fi

if [ -f "$MAIN_SECRET_FILE" ]; then
  awk -F= '/^AGENT_SECRET=/{print $2; exit}' "$MAIN_SECRET_FILE" 2>/dev/null | tr -d '\r'
fi
REMOTE_SECRET
}

resolve_secret() {
  if [ -n "$AGENT_SECRET" ]; then
    echo "AGENT_SECRET recebido por parametro --secret."
    return 0
  fi

  if [ -n "$FETCH_FROM" ]; then
    echo "Buscando AGENT_SECRET em $FETCH_FROM..."
    AGENT_SECRET="$(fetch_secret_from_main "$FETCH_FROM" || true)"

    if [ -n "$AGENT_SECRET" ]; then
      echo "OK: AGENT_SECRET obtido do Portainer principal."
    else
      echo "ATENCAO: nao consegui obter o AGENT_SECRET via SSH."
    fi
  fi

  if [ -z "$AGENT_SECRET" ]; then
    if [ ! -t 0 ]; then
      echo ""
      echo "ERRO: nenhum AGENT_SECRET informado e este comando nao tem terminal interativo."
      echo ""
      echo "Use uma destas formas:"
      echo "  sudo bash update-agent-secret.sh --secret \"SEU_AGENT_SECRET\""
      echo "  sudo bash update-agent-secret.sh --fetch-from root@92.118.59.204"
      echo ""
      echo "Se estiver usando curl, prefira:"
      echo "  curl -fsSL URL_DO_SCRIPT | sudo bash -s -- --fetch-from root@92.118.59.204"
      exit 1
    fi

    echo ""
    echo "Nenhum AGENT_SECRET foi informado por parametro."
    echo "Cole o AGENT_SECRET correto abaixo e pressione Enter."
    printf "AGENT_SECRET: " >&2
    read -r -s AGENT_SECRET
    echo ""
  fi

  if [ -z "$AGENT_SECRET" ]; then
    echo "ERRO: AGENT_SECRET vazio."
    exit 1
  fi
}

save_secret() {
  echo "Salvando AGENT_SECRET em $AGENT_SECRET_FILE..."

  cat > "$AGENT_SECRET_FILE" <<EOF
AGENT_SECRET=$AGENT_SECRET
EOF
  chmod 600 "$AGENT_SECRET_FILE"
  echo "OK: secret salvo com permissao 600."
}

detect_agent_image() {
  if [ -n "$AGENT_IMAGE" ]; then
    echo "$AGENT_IMAGE"
    return 0
  fi

  if docker service inspect "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null 2>&1; then
    docker service inspect "$PORTAINER_AGENT_SERVICE_NAME" \
      --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' \
      | awk -F@ '{print $1}'
    return 0
  fi

  if docker ps -a --format '{{.Names}}' | grep -q "^${PORTAINER_AGENT_SERVICE_NAME}$"; then
    docker inspect "$PORTAINER_AGENT_SERVICE_NAME" --format '{{.Config.Image}}'
    return 0
  fi

  echo "$DEFAULT_AGENT_IMAGE"
}

update_swarm_agent() {
  local image="$1"

  if docker service inspect "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null 2>&1; then
    echo "Atualizando service Swarm '$PORTAINER_AGENT_SERVICE_NAME'..."
    docker service update --env-rm AGENT_SECRET "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null 2>&1 || true
    docker service update \
      --env-add AGENT_SECRET="$AGENT_SECRET" \
      --force \
      "$PORTAINER_AGENT_SERVICE_NAME"
    return 0
  fi

  echo "Service '$PORTAINER_AGENT_SERVICE_NAME' nao existe. Criando em Swarm..."
  docker service create \
    --name "$PORTAINER_AGENT_SERVICE_NAME" \
    --mode global \
    --constraint 'node.platform.os == linux' \
    --publish published="$AGENT_PORT",target=9001,protocol=tcp,mode=host \
    --env AGENT_CLUSTER_ADDR="tasks.${PORTAINER_AGENT_SERVICE_NAME}" \
    --env AGENT_SECRET="$AGENT_SECRET" \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
    --mount type=bind,src=/var/lib/docker/volumes,dst=/var/lib/docker/volumes \
    --mount type=bind,src=/,dst=/host \
    "$image"
}

update_standalone_agent() {
  local image="$1"

  echo "Recriando container standalone '$PORTAINER_AGENT_SERVICE_NAME'..."
  docker rm -f "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null 2>&1 || true

  docker run -d \
    --name "$PORTAINER_AGENT_SERVICE_NAME" \
 

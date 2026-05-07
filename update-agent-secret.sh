#!/usr/bin/env bash
set -euo pipefail

# Atualiza o AGENT_SECRET do Portainer Agent neste servidor.
# Uso recomendado:
#   sudo bash update-agent-secret.sh --fetch-from root@92.118.59.204
# Via curl:
#   curl -fsSL URL | sudo bash -s -- --fetch-from root@92.118.59.204

AGENT_NAME="portainer_agent"
AGENT_SECRET_FILE="/root/portainer-agent-secret.txt"
MAIN_SECRET_FILE="/root/portainer-agent-secret.txt"
AGENT_PORT="9001"
AGENT_IMAGE=""
AGENT_SECRET=""
FETCH_FROM=""
SSH_PORT="22"
SSH_KEY=""

usage() {
  cat <<'EOF'
Uso:
  sudo bash update-agent-secret.sh --fetch-from root@92.118.59.204
  sudo bash update-agent-secret.sh --secret "SEU_AGENT_SECRET"

Opcoes:
  --fetch-from USER@HOST       Busca o secret no Portainer principal via SSH
  --secret SECRET              Usa um secret informado diretamente
  --ssh-port PORT              Porta SSH do principal, padrao 22
  --ssh-key PATH               Chave SSH para acessar o principal
  --main-secret-file PATH      Arquivo fallback de secret no principal
  --image IMAGE                Imagem do agent, se precisar forcar
  --port PORT                  Porta local publicada, padrao 9001
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fetch-from) FETCH_FROM="${2:-}"; shift 2 ;;
    --secret) AGENT_SECRET="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-22}"; shift 2 ;;
    --ssh-key) SSH_KEY="${2:-}"; shift 2 ;;
    --main-secret-file) MAIN_SECRET_FILE="${2:-$MAIN_SECRET_FILE}"; shift 2 ;;
    --image) AGENT_IMAGE="${2:-}"; shift 2 ;;
    --port) AGENT_PORT="${2:-9001}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERRO: parametro desconhecido: $1"; usage; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "ERRO: execute como root."
  echo "Use: sudo bash update-agent-secret.sh --fetch-from root@92.118.59.204"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERRO: Docker nao encontrado neste servidor."
  exit 1
fi

echo "============================================================"
echo " Portainer Agent - atualizar AGENT_SECRET"
echo "============================================================"
echo "Agent local: $AGENT_NAME"
echo "Porta local: $AGENT_PORT"
echo ""

fetch_secret_from_main() {
  local target="$1"
  local ssh_cmd=(ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

  if [ -n "$SSH_KEY" ]; then
    ssh_cmd+=(-i "$SSH_KEY")
  fi

  "${ssh_cmd[@]}" "$target" bash -s -- "$MAIN_SECRET_FILE" <<'REMOTE'
set -e
MAIN_SECRET_FILE="$1"

from_service() {
  docker service inspect "$1" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= '/^AGENT_SECRET=/{print $2; exit}'
}

from_container() {
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= '/^AGENT_SECRET=/{print $2; exit}'
}

find_first() {
  while read -r item; do
    [ -n "$item" ] || continue
    secret="$("$1" "$item" || true)"
    if [ -n "$secret" ]; then
      echo "$secret"
      exit 0
    fi
  done
}

if command -v docker >/dev/null 2>&1; then
  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

  if [ "$swarm_state" = "active" ]; then
    docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null \
      | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
      | awk '{print $1}' \
      | find_first from_service

    docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null \
      | grep -E 'portainer/agent' \
      | awk '{print $1}' \
      | find_first from_service
  fi

  docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null \
    | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
    | awk '{print $1}' \
    | find_first from_container

  docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null \
    | grep -E 'portainer/agent' \
    | awk '{print $1}' \
    | find_first from_container
fi

if [ -f "$MAIN_SECRET_FILE" ]; then
  awk -F= '/^AGENT_SECRET=/{print $2; exit}' "$MAIN_SECRET_FILE" 2>/dev/null | tr -d '\r'
fi
REMOTE
}

get_local_secret() {
  local secret=""

  from_service() {
    docker service inspect "$1" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null \
      | awk -F= '/^AGENT_SECRET=/{print $2; exit}'
  }

  from_container() {
    docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | awk -F= '/^AGENT_SECRET=/{print $2; exit}'
  }

  find_secret_in_items() {
    local reader="$1"
    local item=""

    while read -r item; do
      [ -n "$item" ] || continue
      secret="$("$reader" "$item" || true)"
      if [ -n "$secret" ]; then
        echo "$secret"
        return 0
      fi
    done

    return 1
  }

  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

  if [ "$swarm_state" = "active" ]; then
    docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null \
      | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
      | awk '{print $1}' \
      | find_secret_in_items from_service && return 0

    docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null \
      | grep -E 'portainer/agent' \
      | awk '{print $1}' \
      | find_secret_in_items from_service && return 0
  fi

  docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null \
    | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
    | awk '{print $1}' \
    | find_secret_in_items from_container && return 0

  docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null \
    | grep -E 'portainer/agent' \
    | awk '{print $1}' \
    | find_secret_in_items from_container && return 0

  if [ -f "$AGENT_SECRET_FILE" ]; then
    awk -F= '/^AGENT_SECRET=/{print $2; exit}' "$AGENT_SECRET_FILE" 2>/dev/null | tr -d '\r'
  fi
}

if [ -z "$AGENT_SECRET" ] && [ -n "$FETCH_FROM" ]; then
  echo "Buscando AGENT_SECRET no Portainer principal: $FETCH_FROM"
  AGENT_SECRET="$(fetch_secret_from_main "$FETCH_FROM" | tr -d '\r' | head -n 1 || true)"
fi

if [ -z "$AGENT_SECRET" ]; then
  echo "Tentando detectar AGENT_SECRET neste servidor..."
  AGENT_SECRET="$(get_local_secret | tr -d '\r' | head -n 1 || true)"
fi

if [ -z "$AGENT_SECRET" ]; then
  echo "ERRO: nao consegui obter AGENT_SECRET."
  echo ""
  echo "Use uma destas formas:"
  echo "  sudo bash update-agent-secret.sh --fetch-from root@92.118.59.204"
  echo "  sudo bash update-agent-secret.sh --secret \"SEU_AGENT_SECRET\""
  exit 1
fi

echo "OK: AGENT_SECRET obtido."
echo "Salvando em $AGENT_SECRET_FILE..."
cat > "$AGENT_SECRET_FILE" <<EOF
AGENT_SECRET=$AGENT_SECRET
EOF
chmod 600 "$AGENT_SECRET_FILE"

detect_agent_image() {
  if [ -n "$AGENT_IMAGE" ]; then
    echo "$AGENT_IMAGE"
    return
  fi

  if docker service inspect "$AGENT_NAME" >/dev/null 2>&1; then
    docker service inspect "$AGENT_NAME" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | awk -F@ '{print $1}'
    return
  fi

  if docker ps -a --format '{{.Names}}' | grep -q "^${AGENT_NAME}$"; then
    docker inspect "$AGENT_NAME" --format '{{.Config.Image}}'
    return
  fi

  echo "portainer/agent:2.39.1"
}

IMAGE="$(detect_agent_image)"
SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

echo "Imagem do agent: $IMAGE"
echo "Swarm local: $SWARM_STATE"

if [ "$SWARM_STATE" = "active" ]; then
  if docker service inspect "$AGENT_NAME" >/dev/null 2>&1; then
    echo "Atualizando service Swarm $AGENT_NAME..."
    docker service update --env-rm AGENT_SECRET "$AGENT_NAME" >/dev/null 2>&1 || true
    docker service update --env-add AGENT_SECRET="$AGENT_SECRET" --force "$AGENT_NAME"
  else
    echo "Criando service Swarm $AGENT_NAME..."
    docker service create \
      --name "$AGENT_NAME" \
      --mode global \
      --constraint 'node.platform.os == linux' \
      --publish published="$AGENT_PORT",target=9001,protocol=tcp,mode=host \
      --env AGENT_CLUSTER_ADDR="tasks.${AGENT_NAME}" \
      --env AGENT_SECRET="$AGENT_SECRET" \
      --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
      --mount type=bind,src=/var/lib/docker/volumes,dst=/var/lib/docker/volumes \
      --mount type=bind,src=/,dst=/host \
      "$IMAGE"
  fi
else
  echo "Recriando container standalone $AGENT_NAME..."
  docker rm -f "$AGENT_NAME" >/dev/null 2>&1 || true
  docker run -d \
    --name "$AGENT_NAME" \
    --restart=always \
    -p "${AGENT_PORT}:9001" \
    -e AGENT_SECRET="$AGENT_SECRET" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    -v /:/host \
    "$IMAGE"
fi

echo ""
echo "Validando..."
if ss -lntp | grep -q ":${AGENT_PORT}"; then
  echo "OK: porta ${AGENT_PORT} ouvindo."
else
  echo "ATENCAO: porta ${AGENT_PORT} nao apareceu ouvindo."
fi

docker service ls --filter name="$AGENT_NAME" 2>/dev/null || true
docker ps --filter name="^/${AGENT_NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' 2>/dev/null || true

echo ""
echo "OK: AGENT_SECRET atualizado. Agora de Refresh no environment no Portainer principal."

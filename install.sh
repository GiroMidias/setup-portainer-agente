#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Setup Linux limpo:
# Docker Swarm + Traefik + Portainer Agent protegido
# Com suporte a Cloudflare DNS Challenge
#
# SUPORTE:
# - Debian
# - Ubuntu
#
# Fluxo:
# 1. Detecta sistema operacional
# 2. Coleta dados da instalação local
# 3. Instala Docker
# 4. Inicializa Docker Swarm
# 5. Cria redes overlay proxy e public_network
# 6. Sobe Traefik como stack Swarm
# 7. Pergunta dados SSH do Portainer principal
# 8. Vai ao servidor principal conferir se já existe AGENT_SECRET
# 9. Se existir, reutiliza; se não existir, cria um novo no principal
# 10. Aplica AGENT_SECRET no Portainer Server e nos Agents existentes
# 11. Sobe Portainer Agent local usando o mesmo AGENT_SECRET
# 12. Libera o IP do servidor principal para conectar neste Agent
# 13. Valida conexão do principal para este Agent
# ============================================================

STACK_DIR="/opt/stacks/traefik-portainer-agent"
NETWORK_NAME="proxy"
PUBLIC_NETWORK_NAME="public_network"
TRAEFIK_STACK_NAME="traefik_proxy"
PORTAINER_AGENT_SERVICE_NAME="portainer_agent"

DEFAULT_TRAEFIK_VERSION="v3"
DEFAULT_PORTAINER_AGENT_VERSION="latest"
DEFAULT_LETSENCRYPT_EMAIL="admin@example.com"
DEFAULT_SSH_PORT="22"
DEFAULT_MAIN_SERVER_SSH_USER="root"

AGENT_SECRET_FILE="/root/portainer-agent-secret.txt"
CONFIG_FILE="/root/install-traefik-portainer-agent.conf"

CONFIG_LOADED="no"
FORCE_RECONFIG="${FORCE_RECONFIG:-0}"

# ============================================================
# DETECÇÃO DO SISTEMA OPERACIONAL
# ============================================================

detect_os() {
  echo ""
  echo "============================================================"
  echo " DETECÇÃO DO SISTEMA OPERACIONAL"
  echo "============================================================"

  if [ ! -f /etc/os-release ]; then
    echo "ERRO: não foi possível detectar o sistema operacional."
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  DISTRO_ID="${ID,,}"
  DISTRO_NAME="${PRETTY_NAME:-$ID}"

  case "$DISTRO_ID" in
    debian)
      DOCKER_DISTRO="debian"
      DISTRO_CODENAME="${VERSION_CODENAME:-}"
      ;;
    ubuntu)
      DOCKER_DISTRO="ubuntu"
      DISTRO_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      ;;
    *)
      echo "ERRO: sistema operacional não suportado."
      echo ""
      echo "Sistema detectado: $DISTRO_NAME"
      echo ""
      echo "Sistemas suportados:"
      echo "  - Debian"
      echo "  - Ubuntu"
      exit 1
      ;;
  esac

  if [ -z "$DISTRO_CODENAME" ]; then
    echo "ERRO: não foi possível detectar o codename da distro."
    exit 1
  fi

  ARCH="$(dpkg --print-architecture)"

  echo ""
  echo "Sistema detectado:"
  echo "------------------------------------------------------------"
  echo "Distribuição:      $DISTRO_NAME"
  echo "ID:                $DISTRO_ID"
  echo "Codename:          $DISTRO_CODENAME"
  echo "Arquitetura:       $ARCH"
  echo "Docker Repo:       $DOCKER_DISTRO"
  echo "------------------------------------------------------------"
  echo ""
}

# ============================================================
# INPUTS
# ============================================================

ask_required() {
  local prompt="$1"
  local value=""

  while [ -z "$value" ]; do
    printf "%s" "$prompt" >&2
    read -r value

    if [ -z "$value" ]; then
      echo "Campo obrigatório." >&2
    fi
  done

  echo "$value"
}

ask_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  printf "%s [%s]: " "$prompt" "$default_value" >&2
  read -r value

  echo "${value:-$default_value}"
}

ask_saved_or_default() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local saved_value="${!var_name:-}"

  if [ "$CONFIG_LOADED" = "yes" ] && [ "$FORCE_RECONFIG" != "1" ] && [ -n "$saved_value" ]; then
    echo "Usando valor salvo: $prompt" >&2
    echo "$saved_value"
    return
  fi

  ask_default "$prompt" "$default_value"
}

ask_saved_or_required() {
  local var_name="$1"
  local prompt="$2"
  local saved_value="${!var_name:-}"

  if [ "$CONFIG_LOADED" = "yes" ] && [ "$FORCE_RECONFIG" != "1" ] && [ -n "$saved_value" ]; then
    echo "Usando valor salvo: $prompt" >&2
    echo "$saved_value"
    return
  fi

  ask_required "$prompt"
}

ask_yes_no() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  while true; do
    printf "%s [%s]: " "$prompt" "$default_value" >&2
    read -r value
    value="${value:-$default_value}"

    case "$value" in
      S|s|Y|y|sim|SIM|Sim|yes|YES|Yes)
        echo "yes"
        return
        ;;
      N|n|nao|NAO|Nao|não|NÃO|Não|no|NO|No)
        echo "no"
        return
        ;;
      *)
        echo "Responda com S ou N." >&2
        ;;
    esac
  done
}

ask_ssl_method() {
  local value=""

  echo "" >&2
  echo "Escolha o método de SSL do Traefik:" >&2
  echo "" >&2
  echo "1) SEM Cloudflare - HTTP Challenge padrão" >&2
  echo "2) COM Cloudflare - DNS Challenge" >&2
  echo "" >&2

  while true; do
    printf "Método SSL [1=sem Cloudflare / 2=com Cloudflare]: " >&2
    read -r value
    value="${value:-1}"

    case "$value" in
      1)
        echo "http"
        return
        ;;
      2)
        echo "cloudflare"
        return
        ;;
      *)
        echo "Escolha 1 ou 2." >&2
        ;;
    esac
  done
}

# ============================================================
# HELPERS
# ============================================================

generate_secret() {
  openssl rand -hex 32
}

detect_public_ip() {
  curl -4 -fsSL https://ifconfig.me 2>/dev/null || true
}

run_apt_update() {
  local attempt=1
  local max_attempts=3

  while [ "$attempt" -le "$max_attempts" ]; do
    if apt-get update; then
      return 0
    fi

    echo ""
    echo "AVISO: apt-get update falhou. Tentativa $attempt de $max_attempts."
    echo "Tentando novamente em 3 segundos..."
    sleep 3

    attempt=$((attempt + 1))
  done

  echo "ERRO: apt-get update falhou após $max_attempts tentativas."
  exit 1
}

normalize_yes_no_value() {
  local value="$1"

  case "$value" in
    S|s|Y|y|sim|SIM|Sim|yes|YES|Yes)
      echo "yes"
      ;;
    N|n|nao|NAO|Nao|não|NÃO|Não|no|NO|No)
      echo "no"
      ;;
    *)
      echo "$value"
      ;;
  esac
}

write_config_value() {
  local key="$1"
  local value="$2"

  printf "%s=%q\n" "$key" "$value" >> "$CONFIG_FILE"
}

is_ipv4() {
  local ip="$1"

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# ============================================================
# PERSISTÊNCIA DE CONFIGURAÇÃO
# ============================================================

load_previous_config() {
  if [ -f "$CONFIG_FILE" ]; then
    echo ""
    echo "============================================================"
    echo " CONFIGURAÇÃO ANTERIOR ENCONTRADA"
    echo "============================================================"

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    CONFIG_LOADED="yes"

    echo "Arquivo carregado:"
    echo "$CONFIG_FILE"
    echo ""
    echo "As respostas salvas serão reutilizadas automaticamente."
    echo "Para refazer as perguntas, execute:"
    echo "FORCE_RECONFIG=1 bash $0"
    echo ""
  fi
}

save_config() {
  : > "$CONFIG_FILE"

  write_config_value "AGENT_PUBLIC_IP" "${AGENT_PUBLIC_IP}"
  write_config_value "LETSENCRYPT_EMAIL" "${LETSENCRYPT_EMAIL}"
  write_config_value "TRAEFIK_VERSION" "${TRAEFIK_VERSION}"
  write_config_value "PORTAINER_AGENT_VERSION" "${PORTAINER_AGENT_VERSION}"
  write_config_value "SSL_METHOD" "${SSL_METHOD}"
  write_config_value "CLOUDFLARE_EMAIL" "${CLOUDFLARE_EMAIL}"
  write_config_value "CLOUDFLARE_DNS_API_TOKEN" "${CLOUDFLARE_DNS_API_TOKEN}"
  write_config_value "INSTALL_UFW" "${INSTALL_UFW}"
  write_config_value "ALLOW_SSH" "${ALLOW_SSH}"
  write_config_value "SSH_PORT" "${SSH_PORT}"
  write_config_value "MAIN_SERVER_IP" "${MAIN_SERVER_IP:-}"
  write_config_value "MAIN_SERVER_SSH_USER" "${MAIN_SERVER_SSH_USER:-}"
  write_config_value "MAIN_SERVER_SSH_PORT" "${MAIN_SERVER_SSH_PORT:-}"

  chmod 600 "$CONFIG_FILE"

  echo ""
  echo "Configuração salva em:"
  echo "$CONFIG_FILE"
}

# ============================================================
# DOCKER REPOSITORY
# ============================================================

configure_docker_repository() {
  echo ""
  echo "[3/12] Configurando repositório Docker..."

  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/sources.list.d/docker.sources
  rm -f /etc/apt/keyrings/docker.asc

  apt-get clean
  rm -rf /var/lib/apt/lists/*

  install -m 0755 -d /etc/apt/keyrings

  echo ""
  echo "Baixando chave GPG oficial do Docker..."

  curl -fsSL \
    "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
    -o /etc/apt/keyrings/docker.asc

  chmod a+r /etc/apt/keyrings/docker.asc

  ARCH="$(dpkg --print-architecture)"

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_DISTRO}
Suites: ${DISTRO_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  echo ""
  echo "Repositório Docker configurado:"
  echo "------------------------------------------------------------"
  cat /etc/apt/sources.list.d/docker.sources
  echo "------------------------------------------------------------"

  echo ""
  echo "Atualizando índices APT..."
  run_apt_update

  echo ""
  echo "Validando repositório Docker..."

  if [ ! -f /etc/apt/sources.list.d/docker.sources ]; then
    echo "ERRO: arquivo docker.sources não foi criado."
    exit 1
  fi

  if ! grep -q "download.docker.com/linux/${DOCKER_DISTRO}" /etc/apt/sources.list.d/docker.sources; then
    echo "ERRO: repositório Docker não configurado corretamente."
    exit 1
  fi

  if ! apt-cache show docker-ce >/dev/null 2>&1; then
    echo "ERRO: pacote docker-ce não apareceu no cache do APT."
    echo ""
    echo "Debug:"
    echo "------------------------------------------------------------"
    apt-cache policy docker-ce || true
    echo "------------------------------------------------------------"
    echo ""
    echo "Verifique se a distro/codename é suportada pelo Docker:"
    echo "Distro:   ${DOCKER_DISTRO}"
    echo "Codename: ${DISTRO_CODENAME}"
    echo "Arch:     ${ARCH}"
    exit 1
  fi

  if apt-cache policy docker-ce | grep -q "Candidate: (none)"; then
    echo "ERRO: docker-ce apareceu no cache, mas sem candidato de instalação."
    echo ""
    echo "Debug:"
    echo "------------------------------------------------------------"
    apt-cache policy docker-ce || true
    echo "------------------------------------------------------------"
    exit 1
  fi

  echo "OK: repositório Docker validado."
}

# ============================================================
# NETWORKS
# ============================================================

ensure_overlay_network() {
  local network_name="$1"

  echo ""
  echo "[Rede] Validando rede '$network_name'..."

  if docker network inspect "$network_name" >/dev/null 2>&1; then
    DRIVER="$(docker network inspect "$network_name" --format '{{.Driver}}')"

    if [ "$DRIVER" = "overlay" ]; then
      echo "OK: rede '$network_name' já existe."
      return
    fi

    echo "Rede existe mas não é overlay."
    echo "Removendo e recriando..."

    docker network rm "$network_name" || true
  fi

  docker network create \
    --driver overlay \
    --attachable \
    "$network_name"

  echo "OK: rede '$network_name' criada."
}

# ============================================================
# DOCKER SWARM
# ============================================================

ensure_swarm_manager() {
  echo ""
  echo "[5/12] Validando Docker Swarm..."

  local swarm_state
  local control_available

  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
  control_available="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo "false")"

  if [ "$swarm_state" = "active" ] && [ "$control_available" = "true" ]; then
    echo "OK: este servidor já é manager Swarm."
    return
  fi

  if [ "$swarm_state" = "active" ] && [ "$control_available" != "true" ]; then
    echo "ERRO: este servidor já está em um Swarm, mas não é manager."
    echo "Este instalador precisa rodar em um manager Swarm."
    exit 1
  fi

  echo "Inicializando Docker Swarm..."

  docker swarm init --advertise-addr "$AGENT_PUBLIC_IP"

  echo "OK: Docker Swarm inicializado."
}

# ============================================================
# TRAEFIK
# ============================================================

render_traefik_stack() {
  echo ""
  echo "[7/12] Gerando stack do Traefik..."

  mkdir -p "$STACK_DIR/letsencrypt"

  touch "$STACK_DIR/letsencrypt/acme.json"
  chmod 600 "$STACK_DIR/letsencrypt/acme.json"

  if [ "$SSL_METHOD" = "cloudflare" ]; then
    cat > "$STACK_DIR/docker-compose.yml" <<EOF
version: "3.8"

services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    command:
      - "--api.dashboard=true"
      - "--providers.swarm=true"
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge.delaybeforecheck=0"
      - "--log.level=INFO"
      - "--accesslog=true"
    environment:
      - CF_API_EMAIL=${CLOUDFLARE_EMAIL}
      - CF_DNS_API_TOKEN=${CLOUDFLARE_DNS_API_TOKEN}
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${STACK_DIR}/letsencrypt:/letsencrypt
    networks:
      - ${NETWORK_NAME}
      - ${PUBLIC_NETWORK_NAME}
    deploy:
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

networks:
  ${NETWORK_NAME}:
    external: true
  ${PUBLIC_NETWORK_NAME}:
    external: true
EOF
  else
    cat > "$STACK_DIR/docker-compose.yml" <<EOF
version: "3.8"

services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    command:
      - "--api.dashboard=true"
      - "--providers.swarm=true"
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--log.level=INFO"
      - "--accesslog=true"
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${STACK_DIR}/letsencrypt:/letsencrypt
    networks:
      - ${NETWORK_NAME}
      - ${PUBLIC_NETWORK_NAME}
    deploy:
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

networks:
  ${NETWORK_NAME}:
    external: true
  ${PUBLIC_NETWORK_NAME}:
    external: true
EOF
  fi

  chmod 600 "$STACK_DIR/docker-compose.yml"

  echo "OK: arquivo gerado em $STACK_DIR/docker-compose.yml"
}

deploy_traefik_stack() {
  echo ""
  echo "[8/12] Subindo stack do Traefik..."

  docker stack deploy \
    -c "$STACK_DIR/docker-compose.yml" \
    "$TRAEFIK_STACK_NAME"

  echo "OK: stack do Traefik enviada para o Swarm."
}

# ============================================================
# SSH SERVIDOR PRINCIPAL
# ============================================================

collect_main_server_data() {
  echo ""
  echo "============================================================"
  echo " DADOS DO SERVIDOR PRINCIPAL DO PORTAINER"
  echo "============================================================"
  echo ""
  echo "Agora informe o servidor principal onde o Portainer Server roda."
  echo "Este servidor será usado para buscar/criar o AGENT_SECRET."
  echo ""

  MAIN_SERVER_IP="$(ask_saved_or_required \
    "MAIN_SERVER_IP" \
    "IP público do servidor principal do Portainer: ")"

  MAIN_SERVER_SSH_USER="$(ask_saved_or_default \
    "MAIN_SERVER_SSH_USER" \
    "Usuário SSH do servidor principal" \
    "${MAIN_SERVER_SSH_USER:-$DEFAULT_MAIN_SERVER_SSH_USER}")"

  MAIN_SERVER_SSH_PORT="$(ask_saved_or_default \
    "MAIN_SERVER_SSH_PORT" \
    "Porta SSH do servidor principal" \
    "${MAIN_SERVER_SSH_PORT:-$DEFAULT_SSH_PORT}")"

  save_config
}

ssh_main() {
  ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    -p "$MAIN_SERVER_SSH_PORT" \
    "${MAIN_SERVER_SSH_USER}@${MAIN_SERVER_IP}" \
    "$@"
}

ssh_main_bash() {
  ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    -p "$MAIN_SERVER_SSH_PORT" \
    "${MAIN_SERVER_SSH_USER}@${MAIN_SERVER_IP}" \
    'bash -s' \
    "$@"
}

test_main_server_ssh() {
  echo ""
  echo "[9/12] Testando SSH com o servidor principal..."

  if ! ssh_main "echo OK" >/dev/null; then
    echo "ERRO: não foi possível conectar via SSH no servidor principal."
    echo ""
    echo "Dados usados:"
    echo "Servidor: ${MAIN_SERVER_IP}"
    echo "Usuário:  ${MAIN_SERVER_SSH_USER}"
    echo "Porta:    ${MAIN_SERVER_SSH_PORT}"
    echo ""
    echo "Corrija o acesso SSH e rode novamente."
    echo "As respostas já ficaram salvas em:"
    echo "$CONFIG_FILE"
    exit 1
  fi

  echo "OK: SSH conectado no servidor principal."
}

fetch_or_create_agent_secret_on_principal() {
  ssh_main_bash <<'REMOTE_SCRIPT'
set -euo pipefail

SECRET_FILE="/root/portainer-agent-secret.txt"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

read_secret_file() {
  if $SUDO test -s "$SECRET_FILE" 2>/dev/null; then
    $SUDO cat "$SECRET_FILE" 2>/dev/null | head -n 1 | tr -d '\r\n'
    echo ""
    return 0
  fi

  return 1
}

save_secret_file() {
  local secret="$1"

  printf "%s\n" "$secret" | $SUDO tee "$SECRET_FILE" >/dev/null
  $SUDO chmod 600 "$SECRET_FILE" >/dev/null 2>&1 || true
}

find_secret_in_docker_services() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  local services
  services="$($SUDO docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /portainer\/portainer/ && tolower($2) !~ /portainer\/agent/ {print $1}' || true)"

  if [ -n "$services" ]; then
    for service in $services; do
      local secret
      secret="$($SUDO docker service inspect "$service" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '$1=="AGENT_SECRET"{sub(/^AGENT_SECRET=/,""); print; exit}' || true)"

      if [ -n "$secret" ]; then
        printf "%s\n" "$secret"
        return 0
      fi
    done
  fi

  return 1
}

find_secret_in_docker_containers() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  local containers
  containers="$($SUDO docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /portainer\/portainer/ && tolower($2) !~ /portainer\/agent/ {print $1}' || true)"

  if [ -n "$containers" ]; then
    for container in $containers; do
      local secret
      secret="$($SUDO docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '$1=="AGENT_SECRET"{sub(/^AGENT_SECRET=/,""); print; exit}' || true)"

      if [ -n "$secret" ]; then
        printf "%s\n" "$secret"
        return 0
      fi
    done
  fi

  return 1
}

create_new_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return 0
  fi

  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  echo ""
}

SECRET=""

SECRET="$(read_secret_file || true)"

if [ -z "$SECRET" ]; then
  SECRET="$(find_secret_in_docker_services || true)"
fi

if [ -z "$SECRET" ]; then
  SECRET="$(find_secret_in_docker_containers || true)"
fi

if [ -z "$SECRET" ]; then
  SECRET="$(create_new_secret)"
fi

if [ -z "$SECRET" ]; then
  echo "ERRO: não foi possível obter/criar AGENT_SECRET." >&2
  exit 1
fi

save_secret_file "$SECRET"

printf "%s\n" "$SECRET"
REMOTE_SCRIPT
}

apply_agent_secret_to_principal() {
  echo ""
  echo "[10/12] Aplicando AGENT_SECRET no servidor principal..."

  ssh_main_bash "$AGENT_SECRET" <<'REMOTE_SCRIPT'
set -euo pipefail

SECRET="$1"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "AVISO: Docker não encontrado no servidor principal."
  echo "O secret foi salvo, mas não foi possível atualizar serviços Docker."
  exit 0
fi

PORTAINER_SERVICES="$($SUDO docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /portainer\/portainer/ && tolower($2) !~ /portainer\/agent/ {print $1}' || true)"
AGENT_SERVICES="$($SUDO docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /portainer\/agent/ {print $1}' || true)"

UPDATED_ANY="no"

if [ -n "$PORTAINER_SERVICES" ]; then
  for service in $PORTAINER_SERVICES; do
    echo "Atualizando Portainer Server service: $service"
    $SUDO docker service update --env-rm AGENT_SECRET "$service" >/dev/null 2>&1 || true
    $SUDO docker service update --env-add "AGENT_SECRET=$SECRET" "$service" >/dev/null
    UPDATED_ANY="yes"
  done
fi

if [ -n "$AGENT_SERVICES" ]; then
  for service in $AGENT_SERVICES; do
    echo "Atualizando Portainer Agent service existente: $service"
    $SUDO docker service update --env-rm AGENT_SECRET "$service" >/dev/null 2>&1 || true
    $SUDO docker service update --env-add "AGENT_SECRET=$SECRET" "$service" >/dev/null
    UPDATED_ANY="yes"
  done
fi

if [ "$UPDATED_ANY" = "no" ]; then
  PORTAINER_CONTAINERS="$($SUDO docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /portainer\/portainer/ && tolower($2) !~ /portainer\/agent/ {print $1}' || true)"

  if [ -n "$PORTAINER_CONTAINERS" ]; then
    echo "AVISO: Portainer Server parece estar rodando como container standalone:"
    echo "$PORTAINER_CONTAINERS"
    echo ""
    echo "Não dá para alterar variável AGENT_SECRET em container já criado sem recriar o container."
    echo "O secret foi salvo em /root/portainer-agent-secret.txt no servidor principal."
  else
    echo "AVISO: não encontrei service/container do Portainer Server no servidor principal."
    echo "O secret foi salvo em /root/portainer-agent-secret.txt no servidor principal."
  fi
fi

echo "OK: verificação/aplicação do AGENT_SECRET no principal concluída."
REMOTE_SCRIPT
}

save_agent_secret_locally() {
  echo ""
  echo "Salvando AGENT_SECRET neste servidor Agent..."

  printf "%s\n" "$AGENT_SECRET" > "$AGENT_SECRET_FILE"
  chmod 600 "$AGENT_SECRET_FILE"

  echo "OK: secret salvo em $AGENT_SECRET_FILE"
}

# ============================================================
# PORTAINER AGENT
# ============================================================

deploy_portainer_agent() {
  echo ""
  echo "[11/12] Subindo Portainer Agent protegido por AGENT_SECRET..."

  if docker service inspect "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null 2>&1; then
    echo "Service $PORTAINER_AGENT_SERVICE_NAME já existe. Removendo para recriar limpo..."
    docker service rm "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null || true

    local attempt=1
    while docker service inspect "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null 2>&1; do
      if [ "$attempt" -gt 30 ]; then
        echo "ERRO: service antigo do Portainer Agent não foi removido."
        exit 1
      fi

      sleep 2
      attempt=$((attempt + 1))
    done
  fi

  docker service create \
    --name "$PORTAINER_AGENT_SERVICE_NAME" \
    --mode global \
    --constraint 'node.platform.os == linux' \
    --network "$NETWORK_NAME" \
    --publish mode=host,target=9001,published=9001,protocol=tcp \
    --env "AGENT_SECRET=${AGENT_SECRET}" \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
    --mount type=bind,src=/var/lib/docker/volumes,dst=/var/lib/docker/volumes \
    "portainer/agent:${PORTAINER_AGENT_VERSION}"

  echo "OK: Portainer Agent criado."
}

wait_for_portainer_agent() {
  echo ""
  echo "Aguardando Portainer Agent iniciar..."

  local attempt=1
  local max_attempts=30

  while [ "$attempt" -le "$max_attempts" ]; do
    if docker service ps "$PORTAINER_AGENT_SERVICE_NAME" --format '{{.CurrentState}}' 2>/dev/null | grep -q "Running"; then
      echo "OK: Portainer Agent está em execução."
      return
    fi

    sleep 3
    attempt=$((attempt + 1))
  done

  echo "AVISO: não consegui confirmar o Agent como Running dentro do tempo esperado."
  echo ""
  docker service ps "$PORTAINER_AGENT_SERVICE_NAME" || true
}

# ============================================================
# FIREWALL
# ============================================================

configure_ufw() {
  echo ""
  echo "[12/12] Configurando firewall..."

  if [ "$INSTALL_UFW" != "yes" ]; then
    echo "UFW desativado pela configuração. Pulando firewall."
    return
  fi

  apt-get install -y ufw

  ufw --force reset

  ufw default deny incoming
  ufw default allow outgoing

  if [ "$ALLOW_SSH" = "yes" ]; then
    ufw allow "$SSH_PORT/tcp"
  fi

  ufw allow 80/tcp
  ufw allow 443/tcp

  if is_ipv4 "$MAIN_SERVER_IP"; then
    ufw allow from "$MAIN_SERVER_IP" to any port 9001 proto tcp
    echo "OK: servidor principal liberado para acessar o Agent na porta 9001."
  else
    echo "AVISO: MAIN_SERVER_IP não parece ser IPv4 puro: $MAIN_SERVER_IP"
    echo "Liberando porta 9001/tcp de forma geral para evitar bloqueio."
    ufw allow 9001/tcp
  fi

  ufw --force enable

  echo "OK: UFW configurado."
}

# ============================================================
# VALIDAÇÃO PRINCIPAL -> AGENT
# ============================================================

validate_main_server_can_reach_agent() {
  echo ""
  echo "Validando conexão do servidor principal para este Agent..."

  if ssh_main_bash "$AGENT_PUBLIC_IP" <<'REMOTE_SCRIPT'
set -euo pipefail

TARGET="$1"

if timeout 8 bash -c "cat < /dev/null > /dev/tcp/${TARGET}/9001" 2>/dev/null; then
  exit 0
fi

if command -v curl >/dev/null 2>&1; then
  if curl -fsS --connect-timeout 8 "http://${TARGET}:9001" >/dev/null 2>&1; then
    exit 0
  fi
fi

exit 1
REMOTE_SCRIPT
  then
    echo "OK: servidor principal conseguiu alcançar este Agent na porta 9001."
  else
    echo "AVISO: o servidor principal não conseguiu validar conexão na porta 9001."
    echo ""
    echo "Confira:"
    echo "  - IP público deste Agent: $AGENT_PUBLIC_IP"
    echo "  - Porta liberada: 9001/tcp"
    echo "  - Firewall externo do provedor"
    echo "  - Security group, se existir"
    echo "  - Se o Agent já terminou de iniciar"
  fi
}

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "ERRO: execute como root."
  exit 1
fi

# ============================================================
# DETECT OS
# ============================================================

detect_os

# ============================================================
# LOAD CONFIG
# ============================================================

load_previous_config

# ============================================================
# ETAPA 1
# ============================================================

echo "============================================================"
echo " ETAPA 1: DADOS DA INSTALAÇÃO LOCAL"
echo "============================================================"

AGENT_PUBLIC_IP_DEFAULT="${AGENT_PUBLIC_IP:-$(detect_public_ip)}"

if [ -z "$AGENT_PUBLIC_IP_DEFAULT" ]; then
  AGENT_PUBLIC_IP_DEFAULT="IP_DESTE_SERVIDOR"
fi

AGENT_PUBLIC_IP="$(ask_saved_or_default \
  "AGENT_PUBLIC_IP" \
  "IP público deste servidor Agent" \
  "$AGENT_PUBLIC_IP_DEFAULT")"

LETSENCRYPT_EMAIL="$(ask_saved_or_default \
  "LETSENCRYPT_EMAIL" \
  "E-mail para Let's Encrypt" \
  "${LETSENCRYPT_EMAIL:-$DEFAULT_LETSENCRYPT_EMAIL}")"

TRAEFIK_VERSION="$(ask_saved_or_default \
  "TRAEFIK_VERSION" \
  "Versão do Traefik" \
  "${TRAEFIK_VERSION:-$DEFAULT_TRAEFIK_VERSION}")"

PORTAINER_AGENT_VERSION="$(ask_saved_or_default \
  "PORTAINER_AGENT_VERSION" \
  "Versão do Portainer Agent" \
  "${PORTAINER_AGENT_VERSION:-$DEFAULT_PORTAINER_AGENT_VERSION}")"

if [ "$CONFIG_LOADED" = "yes" ] && [ "$FORCE_RECONFIG" != "1" ] && [ -n "${SSL_METHOD:-}" ]; then
  echo "Usando valor salvo: Método SSL" >&2
  SSL_METHOD="${SSL_METHOD}"
else
  SSL_METHOD="$(ask_ssl_method)"
fi

CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-}"
CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN:-}"

if [ "$SSL_METHOD" = "cloudflare" ]; then
  echo ""
  echo "Configuração Cloudflare"

  CLOUDFLARE_EMAIL="$(ask_saved_or_default \
    "CLOUDFLARE_EMAIL" \
    "E-mail Cloudflare" \
    "$CLOUDFLARE_EMAIL")"

  if [ "$CONFIG_LOADED" = "yes" ] && [ "$FORCE_RECONFIG" != "1" ] && [ -n "$CLOUDFLARE_DNS_API_TOKEN" ]; then
    echo "Usando token Cloudflare salvo." >&2
  else
    printf "Cloudflare API Token: " >&2
    read -r -s CLOUDFLARE_DNS_API_TOKEN
    echo ""

    if [ -z "$CLOUDFLARE_DNS_API_TOKEN" ]; then
      echo "ERRO: token vazio."
      exit 1
    fi
  fi
else
  CLOUDFLARE_EMAIL=""
  CLOUDFLARE_DNS_API_TOKEN=""
fi

INSTALL_UFW="$(ask_saved_or_default \
  "INSTALL_UFW" \
  "Instalar/configurar UFW? (yes/no)" \
  "${INSTALL_UFW:-yes}")"

INSTALL_UFW="$(normalize_yes_no_value "$INSTALL_UFW")"

ALLOW_SSH="${ALLOW_SSH:-yes}"
SSH_PORT="${SSH_PORT:-$DEFAULT_SSH_PORT}"

if [ "$INSTALL_UFW" = "yes" ]; then
  ALLOW_SSH="$(ask_saved_or_default \
    "ALLOW_SSH" \
    "Liberar SSH? (yes/no)" \
    "$ALLOW_SSH")"

  ALLOW_SSH="$(normalize_yes_no_value "$ALLOW_SSH")"

  if [ "$ALLOW_SSH" = "yes" ]; then
    SSH_PORT="$(ask_saved_or_default \
      "SSH_PORT" \
      "Porta SSH" \
      "$SSH_PORT")"
  fi
else
  ALLOW_SSH="no"
fi

save_config

echo ""
echo "============================================================"
echo " ETAPA 2: INSTALAÇÃO"
echo "============================================================"

echo ""
echo "[1/12] Atualizando pacotes..."

run_apt_update

echo ""
echo "[2/12] Instalando dependências básicas..."

apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  apt-transport-https \
  software-properties-common \
  openssl \
  openssh-client \
  iproute2

echo ""
echo "[3/12] Removendo Docker antigo..."

apt-get remove -y \
  docker.io \
  docker-doc \
  docker-compose \
  docker-compose-v2 \
  podman-docker \
  containerd \
  runc || true

configure_docker_repository

echo ""
echo "[4/12] Instalando Docker..."

apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable docker
systemctl restart docker

echo ""
echo "Docker instalado com sucesso."

ensure_swarm_manager

echo ""
echo "[6/12] Criando redes overlay..."

ensure_overlay_network "$NETWORK_NAME"
ensure_overlay_network "$PUBLIC_NETWORK_NAME"

render_traefik_stack
deploy_traefik_stack

collect_main_server_data
test_main_server_ssh

echo ""
echo "Buscando ou criando AGENT_SECRET no servidor principal..."

if ! AGENT_SECRET="$(fetch_or_create_agent_secret_on_principal)"; then
  echo "ERRO: falha ao buscar/criar AGENT_SECRET no servidor principal."
  exit 1
fi

AGENT_SECRET="$(printf "%s" "$AGENT_SECRET" | head -n 1 | tr -d '\r\n')"

if [ -z "$AGENT_SECRET" ]; then
  echo "ERRO: AGENT_SECRET retornou vazio."
  exit 1
fi

echo "OK: AGENT_SECRET obtido do servidor principal."

save_agent_secret_locally
apply_agent_secret_to_principal
deploy_portainer_agent
wait_for_portainer_agent
configure_ufw
validate_main_server_can_reach_agent

echo ""
echo "============================================================"
echo " INSTALAÇÃO FINALIZADA"
echo "============================================================"
echo ""
echo "Servidor Agent:"
echo "  IP:        $AGENT_PUBLIC_IP"
echo "  Endpoint:  $AGENT_PUBLIC_IP:9001"
echo ""
echo "Servidor principal:"
echo "  IP/Host:   $MAIN_SERVER_IP"
echo "  SSH User:  $MAIN_SERVER_SSH_USER"
echo "  SSH Port:  $MAIN_SERVER_SSH_PORT"
echo ""
echo "Arquivos:"
echo "  Config:        $CONFIG_FILE"
echo "  Agent Secret:  $AGENT_SECRET_FILE"
echo "  Stack:         $STACK_DIR/docker-compose.yml"
echo ""
echo "Próximo passo no Portainer principal:"
echo "  Environments > Add environment > Docker Swarm > Agent"
echo "  URL/Endpoint: $AGENT_PUBLIC_IP:9001"
echo ""
echo "IMPORTANTE:"
echo "  O AGENT_SECRET não foi exibido por segurança."
echo "  Ele foi salvo no servidor principal e neste Agent em:"
echo "  /root/portainer-agent-secret.txt"
echo ""

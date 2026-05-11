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
# 7. Sobe Portainer Agent como service Swarm
# 8. Depois pergunta dados SSH do Portainer principal
# 9. Aplica AGENT_SECRET no Portainer Server e nos Agents existentes
# 10. Valida conexão do principal para este Agent
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

AGENT_SECRET_FILE="/root/portainer-agent-secret.txt"

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

  source /etc/os-release

  DISTRO_ID="${ID,,}"
  DISTRO_CODENAME="${VERSION_CODENAME:-}"
  DISTRO_NAME="${PRETTY_NAME:-$ID}"

  case "$DISTRO_ID" in
    debian)
      DOCKER_DISTRO="debian"
      ;;
    ubuntu)
      DOCKER_DISTRO="ubuntu"
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

generate_secret() {
  openssl rand -hex 32
}

detect_public_ip() {
  curl -4 -fsSL https://ifconfig.me 2>/dev/null || true
}

cleanup_old_compose_installation() {
  echo ""
  echo "[Limpeza] Verificando instalação antiga via Docker Compose..."

  if [ -f "$STACK_DIR/docker-compose.yml" ]; then
    echo "Encontrado docker-compose.yml antigo em $STACK_DIR."
    echo "Derrubando stack antiga..."
    cd "$STACK_DIR"
    docker compose down || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^traefik$'; then
    docker rm -f traefik || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^portainer_agent$'; then
    docker rm -f portainer_agent || true
  fi
}

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
# VALIDAÇÕES INICIAIS
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "ERRO: execute como root."
  exit 1
fi

detect_os

echo "============================================================"
echo " ETAPA 1: DADOS DA INSTALAÇÃO LOCAL"
echo "============================================================"

AGENT_PUBLIC_IP_DEFAULT="$(detect_public_ip)"

if [ -z "$AGENT_PUBLIC_IP_DEFAULT" ]; then
  AGENT_PUBLIC_IP_DEFAULT="IP_DESTE_SERVIDOR"
fi

AGENT_PUBLIC_IP="$(ask_default "IP público deste servidor Agent" "$AGENT_PUBLIC_IP_DEFAULT")"

LETSENCRYPT_EMAIL="$(ask_default "E-mail para Let's Encrypt" "$DEFAULT_LETSENCRYPT_EMAIL")"

TRAEFIK_VERSION="$(ask_default "Versão do Traefik" "$DEFAULT_TRAEFIK_VERSION")"

PORTAINER_AGENT_VERSION="$(ask_default "Versão do Portainer Agent" "$DEFAULT_PORTAINER_AGENT_VERSION")"

SSL_METHOD="$(ask_ssl_method)"

CLOUDFLARE_EMAIL=""
CLOUDFLARE_DNS_API_TOKEN=""

if [ "$SSL_METHOD" = "cloudflare" ]; then
  echo ""
  echo "Configuração Cloudflare"

  CLOUDFLARE_EMAIL="$(ask_required "E-mail Cloudflare: ")"

  printf "Cloudflare API Token: " >&2
  read -r -s CLOUDFLARE_DNS_API_TOKEN
  echo ""

  if [ -z "$CLOUDFLARE_DNS_API_TOKEN" ]; then
    echo "ERRO: token vazio."
    exit 1
  fi
fi

INSTALL_UFW="$(ask_yes_no "Instalar/configurar UFW?" "S")"

ALLOW_SSH="yes"
SSH_PORT="$DEFAULT_SSH_PORT"

if [ "$INSTALL_UFW" = "yes" ]; then
  ALLOW_SSH="$(ask_yes_no "Liberar SSH?" "S")"

  if [ "$ALLOW_SSH" = "yes" ]; then
    SSH_PORT="$(ask_default "Porta SSH" "$DEFAULT_SSH_PORT")"
  fi
fi

AGENT_SECRET="$(generate_secret)"

echo ""
echo "============================================================"
echo " RESUMO"
echo "============================================================"

echo "Sistema:                 $DISTRO_NAME"
echo "Docker repo:             $DOCKER_DISTRO"
echo "IP público:              $AGENT_PUBLIC_IP"
echo "Traefik:                 $TRAEFIK_VERSION"
echo "Portainer Agent:         $PORTAINER_AGENT_VERSION"
echo "SSL:                     $SSL_METHOD"
echo "Rede principal:          $NETWORK_NAME"
echo "Rede pública:            $PUBLIC_NETWORK_NAME"

echo ""
CONTINUE_INSTALL="$(ask_yes_no "Continuar instalação?" "S")"

if [ "$CONTINUE_INSTALL" != "yes" ]; then
  echo "Instalação cancelada."
  exit 0
fi

# ============================================================
# INSTALAÇÃO
# ============================================================

echo ""
echo "============================================================"
echo " ETAPA 2: INSTALAÇÃO"
echo "============================================================"

echo ""
echo "[1/11] Atualizando pacotes..."

apt update

apt install -y \
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
echo "[2/11] Removendo Docker antigo..."

apt remove -y \
  docker.io \
  docker-doc \
  docker-compose \
  podman-docker \
  containerd \
  runc || true

echo ""
echo "[3/11] Configurando repositório Docker..."

install -m 0755 -d /etc/apt/keyrings

curl -fsSL \
  "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
  -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${DISTRO_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt update

echo ""
echo "[4/11] Instalando Docker..."

apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable docker
systemctl restart docker

echo ""
echo "[5/11] Inicializando Docker Swarm..."

SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

if [ "$SWARM_STATE" != "active" ]; then
  docker swarm init --advertise-addr "$AGENT_PUBLIC_IP"
else
  echo "Swarm já ativo."
fi

echo ""
echo "[6/11] Limpando instalação antiga..."

cleanup_old_compose_installation

echo ""
echo "[7/11] Criando redes overlay..."

ensure_overlay_network "$NETWORK_NAME"
ensure_overlay_network "$PUBLIC_NETWORK_NAME"

echo ""
echo "[8/11] Criando diretórios..."

mkdir -p "$STACK_DIR/letsencrypt"

touch "$STACK_DIR/letsencrypt/acme.json"

chmod 600 "$STACK_DIR/letsencrypt/acme.json"

echo ""
echo "[9/11] Salvando variáveis..."

cat > "$STACK_DIR/.env" <<EOF
TRAEFIK_VERSION=$TRAEFIK_VERSION
PORTAINER_AGENT_VERSION=$PORTAINER_AGENT_VERSION
NETWORK_NAME=$NETWORK_NAME
PUBLIC_NETWORK_NAME=$PUBLIC_NETWORK_NAME
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
AGENT_SECRET=$AGENT_SECRET
AGENT_PUBLIC_IP=$AGENT_PUBLIC_IP
SSL_METHOD=$SSL_METHOD
CLOUDFLARE_EMAIL=$CLOUDFLARE_EMAIL
CLOUDFLARE_DNS_API_TOKEN=$CLOUDFLARE_DNS_API_TOKEN
EOF

chmod 600 "$STACK_DIR/.env"

cat > "$AGENT_SECRET_FILE" <<EOF
AGENT_SECRET=$AGENT_SECRET
EOF

chmod 600 "$AGENT_SECRET_FILE"

echo ""
echo "[10/11] Gerando stack Traefik..."

if [ "$SSL_METHOD" = "cloudflare" ]; then

cat > "$STACK_DIR/traefik-stack.yml" <<EOF
version: "3.8"

services:

  traefik:
    image: traefik:${TRAEFIK_VERSION}

    command:
      - --providers.swarm=true
      - --providers.swarm.endpoint=unix:///var/run/docker.sock
      - --providers.swarm.exposedbydefault=false
      - --providers.swarm.network=${NETWORK_NAME}

      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443

      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https

      - --certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json

      - --certificatesresolvers.letsencrypt.acme.dnschallenge=true
      - --certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare

    environment:
      - CLOUDFLARE_DNS_API_TOKEN=${CLOUDFLARE_DNS_API_TOKEN}

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

    deploy:
      mode: replicated
      replicas: 1

      placement:
        constraints:
          - node.role == manager

networks:

  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF

else

cat > "$STACK_DIR/traefik-stack.yml" <<EOF
version: "3.8"

services:

  traefik:
    image: traefik:${TRAEFIK_VERSION}

    command:
      - --providers.swarm=true
      - --providers.swarm.endpoint=unix:///var/run/docker.sock
      - --providers.swarm.exposedbydefault=false
      - --providers.swarm.network=${NETWORK_NAME}

      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443

      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https

      - --certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json

      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web

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

    deploy:
      mode: replicated
      replicas: 1

      placement:
        constraints:
          - node.role == manager

networks:

  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF

fi

echo ""
echo "[11/11] Subindo stack..."

docker stack deploy \
  -c "$STACK_DIR/traefik-stack.yml" \
  "$TRAEFIK_STACK_NAME"

echo ""
echo "Criando Portainer Agent..."

docker service rm "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null 2>&1 || true

sleep 5

docker service create \
  --name "$PORTAINER_AGENT_SERVICE_NAME" \
  --network "$NETWORK_NAME" \
  --publish published=9001,target=9001,protocol=tcp,mode=host \
  --mode global \
  --constraint 'node.platform.os == linux' \
  --env AGENT_CLUSTER_ADDR="tasks.${PORTAINER_AGENT_SERVICE_NAME}" \
  --env AGENT_SECRET="$AGENT_SECRET" \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount type=bind,src=/var/lib/docker/volumes,dst=/var/lib/docker/volumes \
  --mount type=bind,src=/,dst=/host \
  "portainer/agent:${PORTAINER_AGENT_VERSION}"

sleep 10

# ============================================================
# FIREWALL
# ============================================================

echo ""
echo "============================================================"
echo " ETAPA 3: FIREWALL"
echo "============================================================"

if [ "$INSTALL_UFW" = "yes" ]; then

  if ! command -v ufw >/dev/null 2>&1; then
    apt install -y ufw
  fi

  if [ "$ALLOW_SSH" = "yes" ]; then
    ufw allow "${SSH_PORT}/tcp"
  fi

  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 9001/tcp

  ufw --force enable

  echo ""
  ufw status numbered
fi

# ============================================================
# TESTES
# ============================================================

echo ""
echo "============================================================"
echo " ETAPA 4: TESTES"
echo "============================================================"

echo ""
echo "Serviços:"

docker service ls

echo ""
echo "Redes:"

docker network ls

echo ""
echo "Teste porta 9001..."

if ss -tulpn | grep -q ':9001'; then
  echo "OK: porta 9001 ouvindo."
else
  echo "ERRO: porta 9001 não está ouvindo."
fi

echo ""
echo "Teste endpoint local..."

curl -k https://127.0.0.1:9001/ping || true

echo ""
echo "============================================================"
echo " INSTALAÇÃO CONCLUÍDA"
echo "============================================================"

echo ""
echo "Endpoint do Agent:"
echo ""
echo "  https://${AGENT_PUBLIC_IP}:9001"
echo ""

echo "AGENT_SECRET:"
echo ""
echo "  $AGENT_SECRET"
echo ""

echo "Arquivo do segredo:"
echo ""
echo "  $AGENT_SECRET_FILE"
echo ""

echo "Comandos úteis:"
echo ""
echo "  docker service ls"
echo "  docker service logs -f portainer_agent"
echo "  docker service logs -f traefik_proxy_traefik"
echo ""

echo "============================================================"

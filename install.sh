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

echo "Removendo repositórios Docker antigos..."

rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/keyrings/docker.asc

apt clean
rm -rf /var/lib/apt/lists/*

install -m 0755 -d /etc/apt/keyrings

curl -fsSL \
  "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
  -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

ARCH="$(dpkg --print-architecture)"

echo \
"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${DISTRO_CODENAME} stable" \
> /etc/apt/sources.list.d/docker.list

echo ""
echo "Repositório configurado:"
cat /etc/apt/sources.list.d/docker.list

echo ""
echo "Atualizando índices APT..."

apt update

echo ""
echo "Validando repositório Docker..."

if ! grep -q "download.docker.com" /etc/apt/sources.list.d/docker.list; then
  echo "ERRO: repositório Docker não configurado."
  exit 1
fi

if ! apt-cache policy docker-ce | grep -q "download.docker.com"; then
  echo ""
  echo "Repositório encontrado:"
  cat /etc/apt/sources.list.d/docker.list
  echo ""
  echo "ERRO: Docker repo não apareceu no apt-cache."
  exit 1
fi

echo "OK: repositório Docker validado."

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
echo "Docker instalado com sucesso."

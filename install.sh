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
CONFIG_FILE="/root/install-traefik-portainer-agent.conf"

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

# ============================================================
# PERSISTÊNCIA DE CONFIGURAÇÃO
# ============================================================

load_previous_config() {
  if [ -f "$CONFIG_FILE" ]; then
    echo ""
    echo "============================================================"
    echo " CONFIGURAÇÃO ANTERIOR ENCONTRADA"
    echo "============================================================"

    source "$CONFIG_FILE"

    echo "Arquivo carregado:"
    echo "$CONFIG_FILE"
    echo ""

    USE_PREVIOUS="$(ask_yes_no "Usar respostas salvas da última instalação?" "S")"

    if [ "$USE_PREVIOUS" != "yes" ]; then
      rm -f "$CONFIG_FILE"

      unset AGENT_PUBLIC_IP
      unset LETSENCRYPT_EMAIL
      unset TRAEFIK_VERSION
      unset PORTAINER_AGENT_VERSION
      unset SSL_METHOD
      unset CLOUDFLARE_EMAIL
      unset CLOUDFLARE_DNS_API_TOKEN
      unset INSTALL_UFW
      unset ALLOW_SSH
      unset SSH_PORT

      echo "Configuração anterior removida."
    fi
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
AGENT_PUBLIC_IP="${AGENT_PUBLIC_IP}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"
TRAEFIK_VERSION="${TRAEFIK_VERSION}"
PORTAINER_AGENT_VERSION="${PORTAINER_AGENT_VERSION}"
SSL_METHOD="${SSL_METHOD}"
CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL}"
CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN}"
INSTALL_UFW="${INSTALL_UFW}"
ALLOW_SSH="${ALLOW_SSH}"
SSH_PORT="${SSH_PORT}"
EOF

  chmod 600 "$CONFIG_FILE"

  echo ""
  echo "Configuração salva em:"
  echo "$CONFIG_FILE"
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

AGENT_PUBLIC_IP="$(ask_default \
  "IP público deste servidor Agent" \
  "$AGENT_PUBLIC_IP_DEFAULT")"

LETSENCRYPT_EMAIL="$(ask_default \
  "E-mail para Let's Encrypt" \
  "${LETSENCRYPT_EMAIL:-$DEFAULT_LETSENCRYPT_EMAIL}")"

TRAEFIK_VERSION="$(ask_default \
  "Versão do Traefik" \
  "${TRAEFIK_VERSION:-$DEFAULT_TRAEFIK_VERSION}")"

PORTAINER_AGENT_VERSION="$(ask_default \
  "Versão do Portainer Agent" \
  "${PORTAINER_AGENT_VERSION:-$DEFAULT_PORTAINER_AGENT_VERSION}")"

if [ -n "${SSL_METHOD:-}" ]; then
  SSL_METHOD="$(ask_default \
    "Método SSL (http/cloudflare)" \
    "$SSL_METHOD")"
else
  SSL_METHOD="$(ask_ssl_method)"
fi

CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-}"
CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN:-}"

if [ "$SSL_METHOD" = "cloudflare" ]; then
  echo ""
  echo "Configuração Cloudflare"

  CLOUDFLARE_EMAIL="$(ask_default \
    "E-mail Cloudflare" \
    "$CLOUDFLARE_EMAIL")"

  if [ -n "$CLOUDFLARE_DNS_API_TOKEN" ]; then
    USE_SAVED_CF_TOKEN="$(ask_yes_no \
      "Usar token Cloudflare salvo?" \
      "S")"

    if [ "$USE_SAVED_CF_TOKEN" != "yes" ]; then
      CLOUDFLARE_DNS_API_TOKEN=""
    fi
  fi

  if [ -z "$CLOUDFLARE_DNS_API_TOKEN" ]; then
    printf "Cloudflare API Token: " >&2
    read -r -s CLOUDFLARE_DNS_API_TOKEN
    echo ""

    if [ -z "$CLOUDFLARE_DNS_API_TOKEN" ]; then
      echo "ERRO: token vazio."
      exit 1
    fi
  fi
fi

INSTALL_UFW="$(ask_default \
  "Instalar/configurar UFW? (yes/no)" \
  "${INSTALL_UFW:-yes}")"

ALLOW_SSH="${ALLOW_SSH:-yes}"
SSH_PORT="${SSH_PORT:-$DEFAULT_SSH_PORT}"

if [ "$INSTALL_UFW" = "yes" ]; then
  ALLOW_SSH="$(ask_default \
    "Liberar SSH? (yes/no)" \
    "$ALLOW_SSH")"

  if [ "$ALLOW_SSH" = "yes" ]; then
    SSH_PORT="$(ask_default \
      "Porta SSH" \
      "$SSH_PORT")"
  fi
fi

save_config

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
echo "Atualizando índices APT..."

apt update

echo ""
echo "Validando repositório Docker..."

if ! grep -q "download.docker.com" /etc/apt/sources.list.d/docker.list; then
  echo "ERRO: repositório Docker não configurado."
  exit 1
fi

if ! apt-cache policy docker-ce | grep -q "download.docker.com"; then
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

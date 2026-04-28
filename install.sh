#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Setup Debian limpo:
# Docker + Docker Compose + Traefik + Portainer Agent protegido
# Com suporte a Cloudflare DNS Challenge
#
# Fluxo:
# 1. Coleta dados da instalação local
# 2. Instala e sobe Traefik + Portainer Agent
# 3. Gera AGENT_SECRET
# 4. Depois pergunta dados SSH do Portainer principal
# 5. Detecta Swarm ou Compose no servidor principal
# 6. Aplica AGENT_SECRET automaticamente
# 7. Valida conexão do Portainer principal para o Agent
# ============================================================

STACK_DIR="/opt/stacks/traefik-portainer-agent"
NETWORK_NAME="proxy"

DEFAULT_TRAEFIK_VERSION="v3"
DEFAULT_PORTAINER_AGENT_VERSION="latest"
DEFAULT_LETSENCRYPT_EMAIL="admin@example.com"
DEFAULT_SSH_PORT="22"

AGENT_SECRET_FILE="/root/portainer-agent-secret.txt"

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
  echo "   - Use se o domínio NÃO estiver usando Cloudflare" >&2
  echo "   - Mais simples" >&2
  echo "   - Precisa das portas 80 e 443 abertas" >&2
  echo "   - Não gera certificado wildcard" >&2
  echo "" >&2
  echo "2) COM Cloudflare - DNS Challenge" >&2
  echo "   - Use se o domínio estiver na Cloudflare" >&2
  echo "   - Recomendado para Cloudflare" >&2
  echo "   - Suporta certificado wildcard" >&2
  echo "   - Precisa de API Token da Cloudflare" >&2
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
        echo "Escolha 1 para SEM Cloudflare ou 2 para COM Cloudflare." >&2
        ;;
    esac
  done
}

generate_secret() {
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

detect_public_ip() {
  curl -4 -fsSL https://ifconfig.me 2>/dev/null || true
}

echo "============================================================"
echo " Setup: Docker + Traefik + Portainer Agent seguro"
echo "============================================================"
echo ""

if [ "$(id -u)" -ne 0 ]; then
  echo "ERRO: execute como root."
  echo "Use:"
  echo "  sudo bash install.sh"
  exit 1
fi

echo "============================================================"
echo " ETAPA 1: DADOS DA INSTALAÇÃO LOCAL"
echo "============================================================"
echo ""

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
  echo "Configuração Cloudflare DNS Challenge"
  echo ""
  echo "O token precisa ter permissões:"
  echo "  Zone / Zone / Read"
  echo "  Zone / DNS / Edit"
  echo ""

  CLOUDFLARE_EMAIL="$(ask_required "E-mail da conta Cloudflare: ")"

  echo ""
  printf "Cloudflare DNS API Token: " >&2
  read -r -s CLOUDFLARE_DNS_API_TOKEN
  echo ""

  if [ -z "$CLOUDFLARE_DNS_API_TOKEN" ]; then
    echo "ERRO: token da Cloudflare vazio."
    exit 1
  fi
fi

INSTALL_UFW="$(ask_yes_no "Instalar/configurar UFW?" "S")"

ALLOW_SSH="yes"
SSH_PORT="$DEFAULT_SSH_PORT"

if [ "$INSTALL_UFW" = "yes" ]; then
  ALLOW_SSH="$(ask_yes_no "Liberar acesso SSH no firewall?" "S")"

  if [ "$ALLOW_SSH" = "yes" ]; then
    SSH_PORT="$(ask_default "Porta SSH local para liberar" "$DEFAULT_SSH_PORT")"
  fi
fi

GENERATE_SECRET="$(ask_yes_no "Gerar AGENT_SECRET automaticamente?" "S")"

if [ "$GENERATE_SECRET" = "yes" ]; then
  AGENT_SECRET="$(generate_secret)"
else
  echo ""
  printf "Digite o AGENT_SECRET manualmente: " >&2
  read -r -s AGENT_SECRET
  echo ""

  if [ -z "$AGENT_SECRET" ]; then
    echo "ERRO: AGENT_SECRET vazio."
    exit 1
  fi
fi

echo ""
echo "Resumo da instalação local:"
echo "------------------------------------------------------------"
echo "Servidor Agent:          $AGENT_PUBLIC_IP"
echo "Stack local:             $STACK_DIR"
echo "Rede Docker:             $NETWORK_NAME"
echo "Traefik:                 $TRAEFIK_VERSION"
echo "Portainer Agent:         $PORTAINER_AGENT_VERSION"
echo "E-mail Let's Encrypt:    $LETSENCRYPT_EMAIL"
echo "Método SSL:              $SSL_METHOD"
echo "Configurar UFW:          $INSTALL_UFW"
echo "Liberar SSH local:       $ALLOW_SSH"

if [ "$ALLOW_SSH" = "yes" ]; then
  echo "Porta SSH local:         $SSH_PORT"
fi

if [ "$SSL_METHOD" = "cloudflare" ]; then
  echo "Cloudflare:              ativado"
  echo "Cloudflare e-mail:       $CLOUDFLARE_EMAIL"
else
  echo "Cloudflare:              desativado"
  echo "SSL:                     HTTP Challenge sem Cloudflare"
fi

echo "AGENT_SECRET:            gerado/definido e será salvo com permissão 600"
echo "------------------------------------------------------------"
echo ""

CONTINUE_INSTALL="$(ask_yes_no "Continuar instalação local?" "S")"

if [ "$CONTINUE_INSTALL" != "yes" ]; then
  echo "Instalação cancelada."
  exit 0
fi

echo ""
echo "============================================================"
echo " ETAPA 2: INSTALAÇÃO LOCAL"
echo "============================================================"

echo ""
echo "[1/9] Atualizando pacotes..."
apt update
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common openssl openssh-client iproute2

echo ""
echo "[2/9] Removendo pacotes Docker conflitantes, se existirem..."
apt remove -y docker.io docker-doc docker-compose podman-docker containerd runc || true

echo ""
echo "[3/9] Configurando repositório oficial do Docker..."
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

DEBIAN_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt update

echo ""
echo "[4/9] Instalando Docker Engine e Docker Compose Plugin..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

echo ""
echo "[5/9] Criando rede Docker '$NETWORK_NAME'..."
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME"

echo ""
echo "[6/9] Criando diretórios da stack..."
mkdir -p "$STACK_DIR/letsencrypt"
touch "$STACK_DIR/letsencrypt/acme.json"
chmod 600 "$STACK_DIR/letsencrypt/acme.json"

echo ""
echo "[7/9] Salvando variáveis protegidas..."
cat > "$STACK_DIR/.env" <<EOF
TRAEFIK_VERSION=$TRAEFIK_VERSION
PORTAINER_AGENT_VERSION=$PORTAINER_AGENT_VERSION
NETWORK_NAME=$NETWORK_NAME
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
AGENT_PUBLIC_IP=$AGENT_PUBLIC_IP
STACK_DIR=$STACK_DIR
SSL_METHOD=$SSL_METHOD
CLOUDFLARE_EMAIL=$CLOUDFLARE_EMAIL
EOF

chmod 600 "$AGENT_SECRET_FILE"

echo ""
echo "[8/9] Gerando docker-compose.yml..."

if [ "$SSL_METHOD" = "cloudflare" ]; then
  cat > "$STACK_DIR/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: traefik
    restart: unless-stopped

    environment:
      - CLOUDFLARE_DNS_API_TOKEN=${CLOUDFLARE_DNS_API_TOKEN}
      - CLOUDFLARE_EMAIL=${CLOUDFLARE_EMAIL}

    command:
      - --api.dashboard=true
      - --api.insecure=false

      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=${NETWORK_NAME}

      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443

      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https

      - --certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json

      - --certificatesresolvers.letsencrypt.acme.dnschallenge=true
      - --certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare
      - --certificatesresolvers.letsencrypt.acme.dnschallenge.delaybeforecheck=10

      - --log.level=INFO
      - --accesslog=true

    ports:
      - "80:80"
      - "443:443"

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt

    networks:
      - proxy

  portainer-agent:
    image: portainer/agent:${PORTAINER_AGENT_VERSION}
    container_name: portainer_agent
    restart: unless-stopped

    # Agent sem labels do Traefik.
    # Nao expor por dominio.
    # Acesso somente via IP:9001, protegido por firewall e AGENT_SECRET.
    ports:
      - "9001:9001"

    environment:
      - AGENT_SECRET=${AGENT_SECRET}

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes

    networks:
      - proxy

networks:
  proxy:
    external: true
EOF

else
  cat > "$STACK_DIR/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: traefik
    restart: unless-stopped

    command:
      - --api.dashboard=true
      - --api.insecure=false

      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=${NETWORK_NAME}

      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443

      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https

      - --certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json

      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web

      - --log.level=INFO
      - --accesslog=true

    ports:
      - "80:80"
      - "443:443"

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt

    networks:
      - proxy

  portainer-agent:
    image: portainer/agent:${PORTAINER_AGENT_VERSION}
    container_name: portainer_agent
    restart: unless-stopped

    # Agent sem labels do Traefik.
    # Nao expor por dominio.
    # Acesso somente via IP:9001, protegido por firewall e AGENT_SECRET.
    ports:
      - "9001:9001"

    environment:
      - AGENT_SECRET=${AGENT_SECRET}

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes

    networks:
      - proxy

networks:
  proxy:
    external: true
EOF
fi

echo ""
echo "[9/9] Subindo Traefik e Portainer Agent..."
cd "$STACK_DIR"
docker compose up -d

echo ""
echo "============================================================"
echo " ETAPA 3: CONFIGURAÇÃO LOCAL DO FIREWALL"
echo "============================================================"

if [ "$INSTALL_UFW" = "yes" ]; then
  if ! command -v ufw >/dev/null 2>&1; then
    apt install -y ufw
  fi

  if [ "$ALLOW_SSH" = "yes" ]; then
    ufw allow "${SSH_PORT}/tcp" || true
  fi

  ufw allow 80/tcp || true
  ufw allow 443/tcp || true

  echo ""
  echo "A porta 9001 será liberada depois que o IP do Portainer principal for informado."
  echo ""

  ufw --force enable

  echo ""
  echo "Status atual do UFW:"
  ufw status numbered || true
else
  echo "Configuração do UFW ignorada por escolha do usuário."
  echo "ATENÇÃO: proteja manualmente a porta 9001."
fi

echo ""
echo "============================================================"
echo " ETAPA 4: TESTES LOCAIS"
echo "============================================================"

echo ""
echo "[Teste local 1] Verificando se o container portainer_agent está rodando..."

if docker ps --format '{{.Names}}' | grep -q '^portainer_agent$'; then
  echo "OK: container portainer_agent está rodando."
else
  echo "ERRO: container portainer_agent não está rodando."
  echo "Verifique com:"
  echo "  docker logs portainer_agent"
fi

echo ""
echo "[Teste local 2] Verificando se a porta 9001 está ouvindo localmente..."

if ss -tulpn | grep -q ':9001'; then
  echo "OK: porta 9001 está ouvindo neste servidor."
else
  echo "ERRO: porta 9001 não está ouvindo."
  echo "Tente:"
  echo "  cd $STACK_DIR"
  echo "  docker compose up -d"
  echo "  docker logs portainer_agent"
fi

echo ""
echo "============================================================"
echo " ETAPA 5: DADOS DO PORTAINER SERVER PRINCIPAL"
echo "============================================================"
echo ""
echo "Agora informe os dados de acesso SSH ao servidor principal."
echo "O script vai entrar nele, detectar Portainer via Swarm ou Compose,"
echo "aplicar o AGENT_SECRET e depois validar conexão com este Agent."
echo ""

CONFIGURE_MAIN="$(ask_yes_no "Configurar automaticamente o Portainer principal agora?" "S")"

MAIN_SERVER_IP=""
MAIN_SSH_USER="root"
MAIN_SSH_PORT="22"
APPLY_SECRET_RESULT="1"
REMOTE_TEST_RESULT="1"

if [ "$CONFIGURE_MAIN" = "yes" ]; then
  MAIN_SERVER_IP="$(ask_required "IP do Portainer Server principal: ")"
  MAIN_SSH_USER="$(ask_default "Usuário SSH do Portainer Server principal" "root")"
  MAIN_SSH_PORT="$(ask_default "Porta SSH do Portainer Server principal" "22")"

  echo ""
  echo "Resumo da configuração do servidor principal:"
  echo "------------------------------------------------------------"
  echo "Portainer principal:     $MAIN_SERVER_IP"
  echo "SSH principal:           $MAIN_SSH_USER@$MAIN_SERVER_IP:$MAIN_SSH_PORT"
  echo "Servidor Agent:          $AGENT_PUBLIC_IP:9001"
  echo "Detecção Portainer:      automática"
  echo "------------------------------------------------------------"
  echo ""

  CONTINUE_MAIN="$(ask_yes_no "Continuar configuração do Portainer principal?" "S")"

  if [ "$CONTINUE_MAIN" = "yes" ]; then
    echo ""
    echo "============================================================"
    echo " ETAPA 6: LIBERANDO 9001 PARA O PORTAINER PRINCIPAL"
    echo "============================================================"

    if [ "$INSTALL_UFW" = "yes" ]; then
      ufw delete allow 9001/tcp >/dev/null 2>&1 || true
      ufw allow from "$MAIN_SERVER_IP" to any port 9001 proto tcp || true

      echo ""
      echo "Porta 9001 liberada somente para:"
      echo "  $MAIN_SERVER_IP"
      echo ""

      ufw status numbered || true
    else
      echo "UFW não foi configurado pelo instalador."
      echo "Regra recomendada:"
      echo "  ufw allow from $MAIN_SERVER_IP to any port 9001 proto tcp"
    fi

    echo ""
    echo "============================================================"
    echo " ETAPA 7: APLICANDO AGENT_SECRET NO PORTAINER PRINCIPAL"
    echo "============================================================"
    echo ""

    set +e

    ssh -p "$MAIN_SSH_PORT" \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "$MAIN_SSH_USER@$MAIN_SERVER_IP" \
      bash -s -- "$AGENT_SECRET" <<'REMOTE_SCRIPT'
set -e

AGENT_SECRET="$1"

echo "Detectando ambiente Docker..."

if ! command -v docker >/dev/null 2>&1; then
  echo "ERRO: Docker não encontrado no servidor principal."
  exit 1
fi

SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

echo "Estado do Swarm: $SWARM_STATE"

if [ "$SWARM_STATE" = "active" ]; then
  echo ""
  echo "Docker Swarm detectado."
  echo "Procurando serviço do Portainer..."

  PORTAINER_SERVICE="$(docker service ls --format '{{.Name}} {{.Image}}' \
    | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
    | awk '{print $1}' \
    | head -n 1)"

  if [ -z "$PORTAINER_SERVICE" ]; then
    echo "ERRO: não foi possível encontrar serviço Portainer no Swarm."
    echo ""
    echo "Serviços existentes:"
    docker service ls
    exit 1
  fi

  echo "Serviço Portainer encontrado: $PORTAINER_SERVICE"
  echo "Removendo AGENT_SECRET antigo, se existir..."

  docker service update --env-rm AGENT_SECRET "$PORTAINER_SERVICE" >/dev/null 2>&1 || true

  echo "Aplicando novo AGENT_SECRET..."

  docker service update \
    --env-add AGENT_SECRET="$AGENT_SECRET" \
    "$PORTAINER_SERVICE"

  echo ""
  echo "OK: AGENT_SECRET aplicado no serviço Swarm: $PORTAINER_SERVICE"
  exit 0
fi

echo ""
echo "Docker Swarm não está ativo."
echo "Tentando detectar instalação via Docker Compose..."

PORTAINER_CONTAINER="$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' \
  | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
  | awk '{print $1}' \
  | head -n 1)"

COMPOSE_FILE=""
COMPOSE_DIR=""
PORTAINER_SERVICE=""

if [ -n "$PORTAINER_CONTAINER" ]; then
  echo "Container Portainer encontrado: $PORTAINER_CONTAINER"

  COMPOSE_PROJECT="$(docker inspect "$PORTAINER_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
  COMPOSE_SERVICE="$(docker inspect "$PORTAINER_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"
  COMPOSE_WORKDIR="$(docker inspect "$PORTAINER_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
  COMPOSE_FILES="$(docker inspect "$PORTAINER_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)"

  if [ -n "$COMPOSE_WORKDIR" ] && [ -n "$COMPOSE_FILES" ] && [ -n "$COMPOSE_SERVICE" ]; then
    FIRST_COMPOSE_FILE="$(echo "$COMPOSE_FILES" | cut -d',' -f1)"

    if [ -f "$FIRST_COMPOSE_FILE" ]; then
      COMPOSE_FILE="$FIRST_COMPOSE_FILE"
      COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
      PORTAINER_SERVICE="$COMPOSE_SERVICE"
    elif [ -f "$COMPOSE_WORKDIR/$FIRST_COMPOSE_FILE" ]; then
      COMPOSE_FILE="$COMPOSE_WORKDIR/$FIRST_COMPOSE_FILE"
      COMPOSE_DIR="$COMPOSE_WORKDIR"
      PORTAINER_SERVICE="$COMPOSE_SERVICE"
    fi
  fi
fi

if [ -z "$COMPOSE_FILE" ]; then
  echo "Não foi possível detectar pelo container. Buscando arquivos compose..."

  SEARCH_DIRS="/root /opt /srv /home"

  for dir in $SEARCH_DIRS; do
    if [ -d "$dir" ]; then
      FOUND_FILE="$(find "$dir" -maxdepth 5 -type f \( \
        -name "docker-compose.yml" -o \
        -name "docker-compose.yaml" -o \
        -name "compose.yml" -o \
        -name "compose.yaml" -o \
        -name "*.yml" -o \
        -name "*.yaml" \
      \) 2>/dev/null | while read -r file; do
        if grep -qE 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' "$file"; then
          echo "$file"
          break
        fi
      done)"

      if [ -n "$FOUND_FILE" ]; then
        COMPOSE_FILE="$FOUND_FILE"
        COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
        break
      fi
    fi
  done
fi

if [ -z "$COMPOSE_FILE" ]; then
  echo "ERRO: não foi possível encontrar arquivo compose com Portainer."
  echo ""
  echo "Dica manual:"
  echo "  find / -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | xargs grep -l 'portainer/portainer'"
  exit 1
fi

COMPOSE_NAME="$(basename "$COMPOSE_FILE")"

echo "Arquivo compose encontrado:"
echo "  $COMPOSE_FILE"

cd "$COMPOSE_DIR"

if [ -z "$PORTAINER_SERVICE" ]; then
  if docker compose -f "$COMPOSE_NAME" config --services >/tmp/portainer_services.txt 2>/dev/null; then
    if grep -q '^portainer$' /tmp/portainer_services.txt; then
      PORTAINER_SERVICE="portainer"
    else
      PORTAINER_SERVICE="$(grep -i 'portainer' /tmp/portainer_services.txt | head -n 1)"
    fi
  fi
fi

if [ -z "$PORTAINER_SERVICE" ]; then
  echo "ERRO: não foi possível detectar o nome do serviço Portainer no Compose."
  echo ""
  echo "Serviços detectados:"
  cat /tmp/portainer_services.txt 2>/dev/null || true
  exit 1
fi

echo "Serviço Compose encontrado: $PORTAINER_SERVICE"

cat > docker-compose.agent-secret.yml <<EOF
services:
  $PORTAINER_SERVICE:
    environment:
      AGENT_SECRET: "$AGENT_SECRET"
EOF

chmod 600 docker-compose.agent-secret.yml

echo "Arquivo docker-compose.agent-secret.yml criado:"
echo "  $COMPOSE_DIR/docker-compose.agent-secret.yml"
echo ""
echo "Aplicando configuração no Portainer Server..."

docker compose -f "$COMPOSE_NAME" -f docker-compose.agent-secret.yml up -d "$PORTAINER_SERVICE"

echo ""
echo "OK: AGENT_SECRET aplicado no serviço Compose: $PORTAINER_SERVICE"
REMOTE_SCRIPT

    APPLY_SECRET_RESULT="$?"

    set -e

    if [ "$APPLY_SECRET_RESULT" = "0" ]; then
      echo ""
      echo "OK: AGENT_SECRET aplicado automaticamente no Portainer Server principal."
    else
      echo ""
      echo "ERRO: não foi possível aplicar automaticamente o AGENT_SECRET no Portainer Server principal."
      echo ""
      echo "O instalador continuará para os testes, mas talvez você precise aplicar manualmente:"
      echo ""
      echo "  AGENT_SECRET=$AGENT_SECRET"
    fi

    echo ""
    echo "============================================================"
    echo " ETAPA 8: VALIDANDO CONEXÃO DO PRINCIPAL PARA O AGENT"
    echo "============================================================"
    echo ""

    set +e

    ssh -p "$MAIN_SSH_PORT" \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "$MAIN_SSH_USER@$MAIN_SERVER_IP" \
      "command -v nc >/dev/null 2>&1 || (apt update && apt install -y netcat-openbsd); nc -vz $AGENT_PUBLIC_IP 9001"

    REMOTE_TEST_RESULT="$?"

    set -e

    if [ "$REMOTE_TEST_RESULT" = "0" ]; then
      echo ""
      echo "OK: o Portainer Server principal consegue acessar o Agent na porta 9001."
    else
      echo ""
      echo "ERRO: o Portainer Server principal não conseguiu acessar o Agent."
      echo ""
      echo "Verifique:"
      echo "  1. IP público do Agent: $AGENT_PUBLIC_IP"
      echo "  2. IP autorizado no UFW: $MAIN_SERVER_IP"
      echo "  3. Porta 9001 no firewall da VPS/provedor"
      echo "  4. Logs do Agent:"
      echo "     docker logs portainer_agent"
      echo ""
      echo "Teste manual no Portainer principal:"
      echo "  nc -vz $AGENT_PUBLIC_IP 9001"
    fi
  else
    echo "Configuração do Portainer principal cancelada."
  fi
else
  echo "Configuração do Portainer principal ignorada."
fi

echo ""
echo "============================================================"
echo " INSTALAÇÃO CONCLUÍDA"
echo "============================================================"
echo ""
echo "Stack local instalada em:"
echo "  $STACK_DIR"
echo ""
echo "AGENT_SECRET salvo em:"
echo "  $AGENT_SECRET_FILE"
echo ""
echo "AGENT_SECRET usado:"
echo ""
echo "  $AGENT_SECRET"
echo ""
echo "Endpoint para cadastrar no Portainer:"
echo "  $AGENT_PUBLIC_IP:9001"
echo ""
echo "Método SSL configurado:"
echo "  $SSL_METHOD"
echo ""

if [ "$SSL_METHOD" = "cloudflare" ]; then
  echo "Cloudflare DNS Challenge está ativado."
  echo "O token foi salvo em:"
  echo "  $STACK_DIR/.env"
  echo ""
fi

if [ "$CONFIGURE_MAIN" = "yes" ]; then
  echo "Configuração automática do Portainer principal:"
  if [ "${APPLY_SECRET_RESULT:-1}" = "0" ]; then
    echo "  OK: AGENT_SECRET aplicado automaticamente."
  else
    echo "  ATENÇÃO: falhou ou não foi confirmado."
  fi

  echo ""
  echo "Validação de conexão:"
  if [ "${REMOTE_TEST_RESULT:-1}" = "0" ]; then
    echo "  OK: o principal acessa $AGENT_PUBLIC_IP:9001."
  else
    echo "  ATENÇÃO: conexão não validada."
  fi
  echo ""
fi

echo "Containers locais:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "Comandos úteis:"
echo "  cd $STACK_DIR"
echo "  docker compose ps"
echo "  docker compose logs -f traefik"
echo "  docker compose logs -f portainer-agent"
echo ""
echo "Para ver o segredo depois:"
echo "  cat $AGENT_SECRET_FILE"
echo "============================================================"

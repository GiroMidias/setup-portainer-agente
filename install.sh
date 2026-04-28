#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Setup Debian limpo:
# Docker + Docker Compose + Traefik + Portainer Agent protegido
# Com suporte a Cloudflare DNS Challenge
# Com aplicação automática do AGENT_SECRET no Portainer Server
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

echo "Preencha os dados da instalação."
echo ""

PORTAINER_SERVER_IP="$(ask_required "IP do Portainer Server autorizado na porta 9001: ")"

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
    SSH_PORT="$(ask_default "Porta SSH para liberar" "$DEFAULT_SSH_PORT")"
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
AUTO_APPLY_SECRET_MAIN="$(ask_yes_no "Aplicar AGENT_SECRET automaticamente no Portainer Server principal via SSH?" "S")"

MAIN_SSH_USER="root"
MAIN_SSH_PORT="22"
MAIN_PORTAINER_DIR=""
MAIN_PORTAINER_SERVICE="portainer"
MAIN_PORTAINER_COMPOSE_FILE="docker-compose.yml"

if [ "$AUTO_APPLY_SECRET_MAIN" = "yes" ]; then
  echo ""
  echo "Configuração automática do Portainer Server principal"
  echo ""
  echo "O instalador vai acessar o servidor principal via SSH,"
  echo "criar um arquivo docker-compose.agent-secret.yml"
  echo "e recriar o serviço do Portainer com o mesmo AGENT_SECRET."
  echo ""

  MAIN_SSH_USER="$(ask_default "Usuário SSH do Portainer Server principal" "root")"
  MAIN_SSH_PORT="$(ask_default "Porta SSH do Portainer Server principal" "22")"
  MAIN_PORTAINER_DIR="$(ask_required "Pasta onde está o docker-compose.yml do Portainer principal: ")"
  MAIN_PORTAINER_SERVICE="$(ask_default "Nome do serviço do Portainer no compose" "portainer")"
  MAIN_PORTAINER_COMPOSE_FILE="$(ask_default "Nome do arquivo compose principal" "docker-compose.yml")"
fi

echo ""
echo "Resumo da instalação:"
echo "------------------------------------------------------------"
echo "Stack:                  $STACK_DIR"
echo "Rede Docker:            $NETWORK_NAME"
echo "Traefik:                $TRAEFIK_VERSION"
echo "Portainer Agent:        $PORTAINER_AGENT_VERSION"
echo "E-mail Let's Encrypt:   $LETSENCRYPT_EMAIL"
echo "Método SSL:             $SSL_METHOD"
echo "IP autorizado 9001:     $PORTAINER_SERVER_IP"
echo "Configurar UFW:         $INSTALL_UFW"
echo "Liberar SSH:            $ALLOW_SSH"

if [ "$ALLOW_SSH" = "yes" ]; then
  echo "Porta SSH:              $SSH_PORT"
fi

if [ "$SSL_METHOD" = "cloudflare" ]; then
  echo "Cloudflare:             ativado"
  echo "Cloudflare e-mail:      $CLOUDFLARE_EMAIL"
else
  echo "Cloudflare:             desativado"
  echo "SSL:                    HTTP Challenge sem Cloudflare"
fi

echo "Aplicar secret principal: $AUTO_APPLY_SECRET_MAIN"

if [ "$AUTO_APPLY_SECRET_MAIN" = "yes" ]; then
  echo "SSH principal:           $MAIN_SSH_USER@$PORTAINER_SERVER_IP:$MAIN_SSH_PORT"
  echo "Pasta Portainer:         $MAIN_PORTAINER_DIR"
  echo "Arquivo compose:         $MAIN_PORTAINER_COMPOSE_FILE"
  echo "Serviço Portainer:       $MAIN_PORTAINER_SERVICE"
fi

echo "AGENT_SECRET:           gerado/definido e será salvo com permissão 600"
echo "------------------------------------------------------------"
echo ""

CONTINUE_INSTALL="$(ask_yes_no "Continuar instalação?" "S")"

if [ "$CONTINUE_INSTALL" != "yes" ]; then
  echo "Instalação cancelada."
  exit 0
fi

echo ""
echo "[1/12] Atualizando pacotes..."
apt update
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common openssl openssh-client iproute2

echo ""
echo "[2/12] Removendo pacotes Docker conflitantes, se existirem..."
apt remove -y docker.io docker-doc docker-compose podman-docker containerd runc || true

echo ""
echo "[3/12] Configurando repositório oficial do Docker..."
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

DEBIAN_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt update

echo ""
echo "[4/12] Instalando Docker Engine e Docker Compose Plugin..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

echo ""
echo "[5/12] Criando rede Docker '$NETWORK_NAME'..."
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME"

echo ""
echo "[6/12] Criando diretórios da stack..."
mkdir -p "$STACK_DIR/letsencrypt"
touch "$STACK_DIR/letsencrypt/acme.json"
chmod 600 "$STACK_DIR/letsencrypt/acme.json"

echo ""
echo "[7/12] Salvando variáveis protegidas..."
cat > "$STACK_DIR/.env" <<EOF
TRAEFIK_VERSION=$TRAEFIK_VERSION
PORTAINER_AGENT_VERSION=$PORTAINER_AGENT_VERSION
NETWORK_NAME=$NETWORK_NAME
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
AGENT_SECRET=$AGENT_SECRET
PORTAINER_SERVER_IP=$PORTAINER_SERVER_IP
SSL_METHOD=$SSL_METHOD
CLOUDFLARE_EMAIL=$CLOUDFLARE_EMAIL
CLOUDFLARE_DNS_API_TOKEN=$CLOUDFLARE_DNS_API_TOKEN
EOF

chmod 600 "$STACK_DIR/.env"

cat > "$AGENT_SECRET_FILE" <<EOF
AGENT_SECRET=$AGENT_SECRET
PORTAINER_SERVER_IP=$PORTAINER_SERVER_IP
STACK_DIR=$STACK_DIR
SSL_METHOD=$SSL_METHOD
CLOUDFLARE_EMAIL=$CLOUDFLARE_EMAIL
EOF

chmod 600 "$AGENT_SECRET_FILE"

echo ""
echo "[8/12] Aplicando AGENT_SECRET no Portainer Server principal..."

if [ "$AUTO_APPLY_SECRET_MAIN" = "yes" ]; then
  echo ""
  echo "============================================================"
  echo " APLICANDO AGENT_SECRET NO PORTAINER SERVER PRINCIPAL"
  echo "============================================================"
  echo ""
  echo "Servidor principal: $MAIN_SSH_USER@$PORTAINER_SERVER_IP"
  echo "Pasta do compose:   $MAIN_PORTAINER_DIR"
  echo "Arquivo compose:    $MAIN_PORTAINER_COMPOSE_FILE"
  echo "Serviço Portainer:  $MAIN_PORTAINER_SERVICE"
  echo ""

  set +e

  ssh -p "$MAIN_SSH_PORT" \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    "$MAIN_SSH_USER@$PORTAINER_SERVER_IP" \
    bash -s -- "$MAIN_PORTAINER_DIR" "$MAIN_PORTAINER_COMPOSE_FILE" "$MAIN_PORTAINER_SERVICE" "$AGENT_SECRET" <<'REMOTE_SCRIPT'
set -e

MAIN_PORTAINER_DIR="$1"
MAIN_PORTAINER_COMPOSE_FILE="$2"
MAIN_PORTAINER_SERVICE="$3"
AGENT_SECRET="$4"

cd "$MAIN_PORTAINER_DIR"

if [ ! -f "$MAIN_PORTAINER_COMPOSE_FILE" ]; then
  echo "ERRO: arquivo $MAIN_PORTAINER_COMPOSE_FILE não encontrado em $MAIN_PORTAINER_DIR"
  exit 1
fi

cat > docker-compose.agent-secret.yml <<EOF
services:
  $MAIN_PORTAINER_SERVICE:
    environment:
      - AGENT_SECRET=$AGENT_SECRET
EOF

chmod 600 docker-compose.agent-secret.yml

echo "Arquivo docker-compose.agent-secret.yml criado."
echo "Aplicando configuração no Portainer Server..."

docker compose -f "$MAIN_PORTAINER_COMPOSE_FILE" -f docker-compose.agent-secret.yml up -d "$MAIN_PORTAINER_SERVICE"

echo "AGENT_SECRET aplicado no Portainer Server principal."
REMOTE_SCRIPT

  APPLY_SECRET_RESULT="$?"

  set -e

  if [ "$APPLY_SECRET_RESULT" = "0" ]; then
    echo ""
    echo "OK: AGENT_SECRET aplicado automaticamente no Portainer Server principal."
  else
    echo ""
    echo "ERRO: não foi possível aplicar o AGENT_SECRET automaticamente no Portainer Server principal."
    echo ""
    echo "Você ainda pode aplicar manualmente usando:"
    echo ""
    echo "  AGENT_SECRET=$AGENT_SECRET"
    echo ""
    echo "Ou acessar o servidor principal e rodar:"
    echo ""
    echo "  cd $MAIN_PORTAINER_DIR"
    echo "  docker compose -f $MAIN_PORTAINER_COMPOSE_FILE -f docker-compose.agent-secret.yml up -d $MAIN_PORTAINER_SERVICE"
  fi
else
  echo "Aplicação automática ignorada por escolha do usuário."
fi

echo ""
echo "[9/12] Gerando docker-compose.yml..."

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
echo "[10/12] Subindo Traefik e Portainer Agent..."
cd "$STACK_DIR"
docker compose up -d

echo ""
echo "[11/12] Configurando firewall..."

if [ "$INSTALL_UFW" = "yes" ]; then
  if ! command -v ufw >/dev/null 2>&1; then
    apt install -y ufw
  fi

  if [ "$ALLOW_SSH" = "yes" ]; then
    ufw allow "${SSH_PORT}/tcp" || true
  fi

  ufw allow 80/tcp || true
  ufw allow 443/tcp || true

  # Remove regra aberta da porta 9001, se existir.
  ufw delete allow 9001/tcp >/dev/null 2>&1 || true

  # Libera 9001 somente para o IP autorizado.
  ufw allow from "$PORTAINER_SERVER_IP" to any port 9001 proto tcp || true

  ufw --force enable

  echo ""
  echo "Status atual do UFW:"
  ufw status numbered || true
else
  echo "Configuração do UFW ignorada por escolha do usuário."
  echo "ATENÇÃO: proteja manualmente a porta 9001."
  echo "Regra recomendada:"
  echo "  ufw allow from $PORTAINER_SERVER_IP to any port 9001 proto tcp"
fi

echo ""
echo "[12/12] Testes de conexão..."
echo ""
echo "============================================================"
echo " TESTES DE CONEXÃO"
echo "============================================================"

echo ""
echo "[Teste 1] Verificando se o container portainer_agent está rodando..."

if docker ps --format '{{.Names}}' | grep -q '^portainer_agent$'; then
  echo "OK: container portainer_agent está rodando."
else
  echo "ERRO: container portainer_agent não está rodando."
  echo "Verifique com:"
  echo "  docker logs portainer_agent"
fi

echo ""
echo "[Teste 2] Verificando se a porta 9001 está ouvindo localmente..."

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
echo "[Teste 3] Teste real a partir do Portainer Server principal"
echo ""
echo "Esse teste usa SSH para entrar no Portainer Server principal"
echo "e de lá testar conexão com este Agent na porta 9001."
echo ""

REMOTE_TEST="$(ask_yes_no "Deseja testar via SSH a partir do Portainer Server principal?" "S")"

if [ "$REMOTE_TEST" = "yes" ]; then
  AGENT_PUBLIC_IP="$(ask_required "IP público deste servidor Agent: ")"
  SSH_USER_MAIN="$(ask_default "Usuário SSH do Portainer Server principal" "$MAIN_SSH_USER")"
  SSH_PORT_MAIN="$(ask_default "Porta SSH do Portainer Server principal" "$MAIN_SSH_PORT")"

  echo ""
  echo "Testando conexão remota:"
  echo "  Origem:  $SSH_USER_MAIN@$PORTAINER_SERVER_IP"
  echo "  Destino: $AGENT_PUBLIC_IP:9001"
  echo ""

  set +e

  ssh -p "$SSH_PORT_MAIN" \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    "$SSH_USER_MAIN@$PORTAINER_SERVER_IP" \
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
    echo "Correção mais comum:"
    echo "  sudo ufw delete allow 9001/tcp"
    echo "  sudo ufw allow from $PORTAINER_SERVER_IP to any port 9001 proto tcp"
    echo ""
    echo "Confira as regras:"
    echo "  sudo ufw status numbered"
    echo ""
    echo "Confira se o Agent está rodando:"
    echo "  docker ps"
    echo "  docker logs portainer_agent"
    echo ""
    echo "Teste manual no Portainer principal:"
    echo "  nc -vz $AGENT_PUBLIC_IP 9001"
  fi
else
  echo ""
  echo "Teste remoto ignorado."
  echo ""
  echo "Para testar manualmente no Portainer Server principal, rode:"
  echo "  nc -vz IP_DESTE_SERVIDOR_AGENT 9001"
fi

echo ""
echo "============================================================"
echo " INSTALAÇÃO CONCLUÍDA"
echo "============================================================"
echo ""
echo "Stack instalada em:"
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
echo "  IP_DESTE_SERVIDOR:9001"
echo ""
echo "A porta 9001 foi configurada para aceitar somente:"
echo "  $PORTAINER_SERVER_IP"
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

if [ "$AUTO_APPLY_SECRET_MAIN" = "yes" ]; then
  echo "Aplicação automática no Portainer Server principal:"
  if [ "${APPLY_SECRET_RESULT:-1}" = "0" ]; then
    echo "  OK: AGENT_SECRET aplicado automaticamente."
  else
    echo "  ATENÇÃO: falhou ou não foi confirmado. Verifique manualmente no servidor principal."
  fi
  echo ""
fi

echo "Containers:"
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
echo ""
echo "IMPORTANTE:"
echo "  Se a aplicação automática no Portainer principal falhar,"
echo "  configure manualmente o mesmo AGENT_SECRET no Portainer Server."
echo "============================================================"

#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Setup Debian limpo:
# Docker + Docker Compose + Traefik + Portainer Agent protegido
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
    read -r -p "$prompt" value
    if [ -z "$value" ]; then
      echo "Campo obrigatório."
    fi
  done

  echo "$value"
}

ask_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  read -r -p "$prompt [$default_value]: " value
  echo "${value:-$default_value}"
}

ask_yes_no() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  while true; do
    read -r -p "$prompt [$default_value]: " value
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
        echo "Responda com S ou N."
        ;;
    esac
  done
}

echo "============================================================"
echo " Setup: Docker + Traefik + Portainer Agent seguro"
echo "============================================================"
echo ""

if [ "$(id -u)" -ne 0 ]; then
  echo "ERRO: execute como root."
  echo "Use:"
  echo "  sudo bash setup-traefik-portainer-agent.sh"
  exit 1
fi

echo "Preencha os dados da instalação."
echo ""

PORTAINER_SERVER_IP="$(ask_required "IP do Portainer Server autorizado na porta 9001: ")"

LETSENCRYPT_EMAIL="$(ask_default "E-mail para Let's Encrypt" "$DEFAULT_LETSENCRYPT_EMAIL")"

TRAEFIK_VERSION="$(ask_default "Versão do Traefik" "$DEFAULT_TRAEFIK_VERSION")"

PORTAINER_AGENT_VERSION="$(ask_default "Versão do Portainer Agent" "$DEFAULT_PORTAINER_AGENT_VERSION")"

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
  AGENT_SECRET="$(openssl rand -hex 32)"
else
  echo ""
  read -r -s -p "Digite o AGENT_SECRET manualmente: " AGENT_SECRET
  echo ""

  if [ -z "$AGENT_SECRET" ]; then
    echo "ERRO: AGENT_SECRET vazio."
    exit 1
  fi
fi

echo ""
echo "Resumo da instalação:"
echo "------------------------------------------------------------"
echo "Stack:                  $STACK_DIR"
echo "Rede Docker:            $NETWORK_NAME"
echo "Traefik:                $TRAEFIK_VERSION"
echo "Portainer Agent:        $PORTAINER_AGENT_VERSION"
echo "E-mail Let's Encrypt:   $LETSENCRYPT_EMAIL"
echo "IP autorizado 9001:     $PORTAINER_SERVER_IP"
echo "Configurar UFW:         $INSTALL_UFW"
echo "Liberar SSH:            $ALLOW_SSH"
if [ "$ALLOW_SSH" = "yes" ]; then
  echo "Porta SSH:              $SSH_PORT"
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
echo "[1/10] Atualizando pacotes..."
apt update
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common openssl

echo ""
echo "[2/10] Removendo pacotes Docker conflitantes, se existirem..."
apt remove -y docker.io docker-doc docker-compose podman-docker containerd runc || true

echo ""
echo "[3/10] Configurando repositório oficial do Docker..."
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

DEBIAN_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt update

echo ""
echo "[4/10] Instalando Docker Engine e Docker Compose Plugin..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

echo ""
echo "[5/10] Criando rede Docker '$NETWORK_NAME'..."
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME"

echo ""
echo "[6/10] Criando diretórios da stack..."
mkdir -p "$STACK_DIR/letsencrypt"
touch "$STACK_DIR/letsencrypt/acme.json"
chmod 600 "$STACK_DIR/letsencrypt/acme.json"

echo ""
echo "[7/10] Salvando variáveis protegidas..."
cat > "$STACK_DIR/.env" <<EOF
TRAEFIK_VERSION=$TRAEFIK_VERSION
PORTAINER_AGENT_VERSION=$PORTAINER_AGENT_VERSION
NETWORK_NAME=$NETWORK_NAME
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
AGENT_SECRET=$AGENT_SECRET
PORTAINER_SERVER_IP=$PORTAINER_SERVER_IP
EOF

chmod 600 "$STACK_DIR/.env"

cat > "$AGENT_SECRET_FILE" <<EOF
AGENT_SECRET=$AGENT_SECRET
PORTAINER_SERVER_IP=$PORTAINER_SERVER_IP
STACK_DIR=$STACK_DIR
EOF

chmod 600 "$AGENT_SECRET_FILE"

echo ""
echo "[8/10] Gerando docker-compose.yml..."
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

echo ""
echo "[9/10] Subindo Traefik e Portainer Agent..."
cd "$STACK_DIR"
docker compose up -d

echo ""
echo "[10/10] Configurando firewall..."

if [ "$INSTALL_UFW" = "yes" ]; then
  if ! command -v ufw >/dev/null 2>&1; then
    apt install -y ufw
  fi

  if [ "$ALLOW_SSH" = "yes" ]; then
    ufw allow "${SSH_PORT}/tcp" || true
  fi

  ufw allow 80/tcp || true
  ufw allow 443/tcp || true

  ufw delete allow 9001/tcp >/dev/null 2>&1 || true
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
echo "Use este mesmo AGENT_SECRET no seu Portainer Server:"
echo ""
echo "  $AGENT_SECRET"
echo ""
echo "Endpoint para cadastrar no Portainer:"
echo "  IP_DESTE_SERVIDOR:9001"
echo ""
echo "A porta 9001 foi configurada para aceitar somente:"
echo "  $PORTAINER_SERVER_IP"
echo ""
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
echo "  Configure o mesmo AGENT_SECRET no container do Portainer Server."
echo "============================================================"
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
  SSH_USER_MAIN="$(ask_default "Usuário SSH do Portainer Server principal" "root")"
  SSH_PORT_MAIN="$(ask_default "Porta SSH do Portainer Server principal" "22")"

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

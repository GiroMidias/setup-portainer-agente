#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Setup Debian limpo:
# Docker Swarm + Traefik + Portainer Agent protegido
# Com suporte a Cloudflare DNS Challenge
#
# Fluxo:
# 1. Coleta dados da instalação local
# 2. Instala Docker
# 3. Inicializa Docker Swarm
# 4. Cria redes overlay proxy e public_network
# 5. Sobe Traefik como stack Swarm
# 6. Sobe Portainer Agent como service Swarm
# 7. Depois pergunta dados SSH do Portainer principal
# 8. Aplica AGENT_SECRET no Portainer Server e nos Agents existentes
# 9. Valida conexão do principal para este Agent
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

read_local_agent_secret() {
  local secret_file="$1"

  if [ -f "$secret_file" ]; then
    awk -F= '/^AGENT_SECRET=/{print $2; exit}' "$secret_file" 2>/dev/null | tr -d '\r' || true
  fi

  return 0
}

fetch_main_agent_secret() {
  local main_server_ip="$1"
  local main_ssh_user="$2"
  local main_ssh_port="$3"
  local main_secret_file="$4"

  ssh -p "$main_ssh_port" \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    "$main_ssh_user@$main_server_ip" \
    bash -s -- "$main_secret_file" <<'REMOTE_SECRET'
set -e

MAIN_SECRET_FILE="$1"

if [ -f "$MAIN_SECRET_FILE" ]; then
  awk -F= '/^AGENT_SECRET=/{print $2; exit}' "$MAIN_SECRET_FILE" 2>/dev/null | tr -d '\r'
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  exit 0
fi

SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

if [ "$SWARM_STATE" = "active" ]; then
  PORTAINER_SERVICES="$(docker service ls --format '{{.Name}} {{.Image}}' \
    | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
    | awk '{print $1}' || true)"

  for service in $PORTAINER_SERVICES; do
    docker service inspect "$service" \
      --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null \
      | awk -F= '/^AGENT_SECRET=/{print $2; exit}'
  done | awk 'NF{print; exit}'

  exit 0
fi

PORTAINER_CONTAINERS="$(docker ps --format '{{.ID}} {{.Image}}' \
  | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
  | awk '{print $1}' || true)"

for container in $PORTAINER_CONTAINERS; do
  docker inspect "$container" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= '/^AGENT_SECRET=/{print $2; exit}'
done | awk 'NF{print; exit}'
REMOTE_SECRET
}

network_has_active_endpoints() {
  local network_name="$1"

  docker network inspect "$network_name" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -q '[a-zA-Z0-9]'
}

print_network_endpoints() {
  local network_name="$1"

  docker network inspect "$network_name" --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null || true
}

ensure_overlay_network() {
  local network_name="$1"
  local required="$2"

  echo ""
  echo "[Rede] Validando rede '$network_name'..."

  if docker network inspect "$network_name" >/dev/null 2>&1; then
    local driver
    driver="$(docker network inspect "$network_name" --format '{{.Driver}}')"

    if [ "$driver" = "overlay" ]; then
      echo "OK: rede '$network_name' já existe como overlay."
      return 0
    fi

    echo "ATENÇÃO: rede '$network_name' existe, mas está como '$driver'."
    echo "Para Swarm, ela precisa ser 'overlay'."

    if network_has_active_endpoints "$network_name"; then
      echo ""
      echo "A rede '$network_name' tem containers ativos, então o instalador NÃO vai remover para não quebrar serviços."
      echo ""
      echo "Containers conectados:"
      print_network_endpoints "$network_name"
      echo ""

      if [ "$required" = "yes" ]; then
        echo "ERRO: a rede '$network_name' é obrigatória como overlay para continuar."
        echo ""
        echo "Corrija manualmente:"
        echo "  1. Remova/pare as stacks que usam '$network_name'"
        echo "  2. Remova a rede:"
        echo "     docker network rm $network_name"
        echo "  3. Crie como overlay:"
        echo "     docker network create --driver overlay --attachable $network_name"
        exit 1
      fi

      echo "Aviso: '$network_name' não foi alterada."
      return 1
    fi

    echo "A rede '$network_name' não tem endpoints ativos. Recriando como overlay..."
    docker network rm "$network_name"
    docker network create --driver overlay --attachable "$network_name"
    echo "OK: rede '$network_name' criada como overlay."
    return 0
  fi

  echo "Criando rede '$network_name' como overlay..."
  docker network create --driver overlay --attachable "$network_name"
  echo "OK: rede '$network_name' criada como overlay."
  return 0
}

cleanup_old_compose_installation() {
  echo ""
  echo "[Limpeza] Verificando instalação antiga via Docker Compose..."

  if [ -f "$STACK_DIR/docker-compose.yml" ]; then
    echo "Encontrado docker-compose.yml antigo em $STACK_DIR."
    echo "Derrubando stack antiga para migrar para Swarm..."
    cd "$STACK_DIR"
    docker compose down || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^traefik$'; then
    echo "Removendo container antigo: traefik"
    docker rm -f traefik || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^portainer_agent$'; then
    echo "Removendo container antigo: portainer_agent"
    docker rm -f portainer_agent || true
  fi
}

echo "============================================================"
echo " Setup: Docker Swarm + Traefik + Portainer Agent seguro"
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

MAIN_SERVER_IP=""
MAIN_SSH_USER="root"
MAIN_SSH_PORT="22"
CONFIGURE_MAIN="no"
APPLY_SECRET_TO_MAIN="no"
APPLY_SECRET_RESULT="1"
REMOTE_TEST_RESULT="1"

echo ""
echo "Modo do AGENT_SECRET:"
echo "  reuse    = recomendado; usa o secret já existente no Portainer principal"
echo "  generate = gera um novo secret; use só no primeiro bootstrap ou rotação planejada"
echo "  manual   = você cola o secret atual manualmente"
echo ""

AGENT_SECRET_MODE="$(ask_default "Modo do AGENT_SECRET" "reuse")"

case "$AGENT_SECRET_MODE" in
  reuse|REUSE|Reuse)
    AGENT_SECRET="$(read_local_agent_secret "$AGENT_SECRET_FILE")"

    if [ -n "$AGENT_SECRET" ]; then
      echo "OK: AGENT_SECRET local encontrado em $AGENT_SECRET_FILE."
    else
      echo ""
      echo "Para não substituir os outros agents, vou buscar o AGENT_SECRET atual no Portainer principal."
      MAIN_SERVER_IP="$(ask_required "IP do Portainer Server principal: ")"
      MAIN_SSH_USER="$(ask_default "Usuário SSH do Portainer Server principal" "root")"
      MAIN_SSH_PORT="$(ask_default "Porta SSH do Portainer Server principal" "22")"

      set +e
      AGENT_SECRET="$(fetch_main_agent_secret "$MAIN_SERVER_IP" "$MAIN_SSH_USER" "$MAIN_SSH_PORT" "$AGENT_SECRET_FILE")"
      FETCH_SECRET_RESULT="$?"
      set -e

      if [ "$FETCH_SECRET_RESULT" != "0" ] || [ -z "$AGENT_SECRET" ]; then
        echo ""
        echo "ERRO: não consegui buscar o AGENT_SECRET no Portainer principal."
        echo "Isso evita sobrescrever o secret do principal e derrubar os outros agents."
        echo ""
        echo "Opções seguras:"
        echo "  1. Rode novamente e escolha modo 'manual' colando o AGENT_SECRET atual"
        echo "  2. Rode no principal: cat $AGENT_SECRET_FILE"
        echo "  3. Se for bootstrap inicial, rode novamente e escolha modo 'generate'"
        exit 1
      fi

      echo "OK: AGENT_SECRET atual obtido do Portainer principal."
      CONFIGURE_MAIN="yes"
    fi

    APPLY_SECRET_TO_MAIN="no"
    ;;
  generate|GENERATE|Generate)
    echo ""
    echo "ATENÇÃO: gerar um novo AGENT_SECRET pode desconectar agents antigos se o principal for atualizado."
    CONFIRM_GENERATE="$(ask_yes_no "Confirmar geração de novo AGENT_SECRET?" "N")"

    if [ "$CONFIRM_GENERATE" != "yes" ]; then
      echo "Geração cancelada para proteger os agents existentes."
      exit 1
    fi

    AGENT_SECRET="$(generate_secret)"
    APPLY_SECRET_TO_MAIN="$(ask_yes_no "Aplicar este novo AGENT_SECRET no Portainer principal?" "N")"
    ;;
  manual|MANUAL|Manual)
    echo ""
    printf "Digite o AGENT_SECRET atual: " >&2
    read -r -s AGENT_SECRET
    echo ""

    if [ -z "$AGENT_SECRET" ]; then
      echo "ERRO: AGENT_SECRET vazio."
      exit 1
    fi

    APPLY_SECRET_TO_MAIN="$(ask_yes_no "Aplicar/rotacionar este AGENT_SECRET no Portainer principal?" "N")"
    ;;
  *)
    echo "ERRO: modo inválido. Use reuse, generate ou manual."
    exit 1
    ;;
esac

echo ""
echo "Resumo da instalação local:"
echo "------------------------------------------------------------"
echo "Servidor Agent:          $AGENT_PUBLIC_IP"
echo "Stack local:             $STACK_DIR"
echo "Rede Traefik/Agent:      $NETWORK_NAME"
echo "Rede pública padrão:     $PUBLIC_NETWORK_NAME"
echo "Traefik:                 $TRAEFIK_VERSION"
echo "Portainer Agent:         $PORTAINER_AGENT_VERSION"
echo "E-mail Let's Encrypt:    $LETSENCRYPT_EMAIL"
echo "Método SSL:              $SSL_METHOD"
echo "Docker Swarm:            será inicializado automaticamente"
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

echo "Volumes externos:        não serão criados automaticamente"
echo "AGENT_SECRET:            modo $AGENT_SECRET_MODE; será salvo com permissão 600"
echo "Aplicar no principal:    $APPLY_SECRET_TO_MAIN"
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
echo "[1/10] Atualizando pacotes..."
apt update
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common openssl openssh-client iproute2

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
echo "[5/10] Inicializando Docker Swarm..."

SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

if [ "$SWARM_STATE" = "active" ]; then
  echo "OK: Docker Swarm já está ativo."
else
  echo "Docker Swarm não está ativo. Inicializando..."
  docker swarm init --advertise-addr "$AGENT_PUBLIC_IP"
  echo "OK: Docker Swarm inicializado."
fi

echo ""
echo "[6/10] Limpando instalação antiga, se existir..."
cleanup_old_compose_installation

echo ""
echo "[7/10] Criando redes overlay..."
ensure_overlay_network "$NETWORK_NAME" "yes"
ensure_overlay_network "$PUBLIC_NETWORK_NAME" "no" || true

echo ""
echo "[8/10] Criando diretórios da stack..."
mkdir -p "$STACK_DIR/letsencrypt"
touch "$STACK_DIR/letsencrypt/acme.json"
chmod 600 "$STACK_DIR/letsencrypt/acme.json"

echo ""
echo "[9/10] Salvando variáveis protegidas..."
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
AGENT_PUBLIC_IP=$AGENT_PUBLIC_IP
STACK_DIR=$STACK_DIR
SSL_METHOD=$SSL_METHOD
CLOUDFLARE_EMAIL=$CLOUDFLARE_EMAIL
NETWORK_NAME=$NETWORK_NAME
PUBLIC_NETWORK_NAME=$PUBLIC_NETWORK_NAME
EOF

chmod 600 "$AGENT_SECRET_FILE"

echo ""
echo "[10/10] Gerando stack Swarm do Traefik..."

if [ "$SSL_METHOD" = "cloudflare" ]; then
  cat > "$STACK_DIR/traefik-stack.yml" <<EOF
version: "3.8"

services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    command:
      - --api.dashboard=true
      - --api.insecure=false

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
      - --certificatesresolvers.letsencrypt.acme.dnschallenge.delaybeforecheck=10

      - --log.level=INFO
      - --accesslog=true

    environment:
      - CLOUDFLARE_DNS_API_TOKEN=${CLOUDFLARE_DNS_API_TOKEN}
      - CLOUDFLARE_EMAIL=${CLOUDFLARE_EMAIL}

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
      - --api.dashboard=true
      - --api.insecure=false

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

      - --log.level=INFO
      - --accesslog=true

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
echo "============================================================"
echo " ETAPA 3: SUBINDO TRAEFIK E PORTAINER AGENT EM SWARM"
echo "============================================================"

echo ""
echo "[Traefik] Deploy da stack Swarm..."
docker stack deploy -c "$STACK_DIR/traefik-stack.yml" "$TRAEFIK_STACK_NAME"

echo ""
echo "[Portainer Agent] Recriando service Swarm..."

if docker service inspect "$PORTAINER_AGENT_SERVICE_NAME" >/dev/null 2>&1; then
  echo "Service '$PORTAINER_AGENT_SERVICE_NAME' já existe. Removendo para recriar corretamente..."
  docker service rm "$PORTAINER_AGENT_SERVICE_NAME"
  sleep 5
fi

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

echo ""
echo "Aguardando serviços iniciarem..."
sleep 10

echo ""
echo "============================================================"
echo " ETAPA 4: CONFIGURAÇÃO LOCAL DO FIREWALL"
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
echo " ETAPA 5: TESTES LOCAIS"
echo "============================================================"

echo ""
echo "[Teste local 1] Verificando serviços Swarm..."

docker service ls | grep -E "${TRAEFIK_STACK_NAME}_traefik|${PORTAINER_AGENT_SERVICE_NAME}" || true

echo ""
echo "[Teste local 2] Verificando Portainer Agent..."

AGENT_REPLICAS="$(docker service ls --filter name="$PORTAINER_AGENT_SERVICE_NAME" --format '{{.Replicas}}' | head -n 1 || true)"

if echo "$AGENT_REPLICAS" | grep -q '1/1'; then
  echo "OK: Portainer Agent Swarm está rodando: $AGENT_REPLICAS"
else
  echo "ATENÇÃO: Portainer Agent pode não estar saudável: $AGENT_REPLICAS"
  echo ""
  echo "Logs:"
  docker service logs --tail 80 "$PORTAINER_AGENT_SERVICE_NAME" || true
fi

echo ""
echo "[Teste local 3] Verificando se a porta 9001 está ouvindo..."

if ss -tulpn | grep -q ':9001'; then
  echo "OK: porta 9001 está ouvindo neste servidor."
else
  echo "ERRO: porta 9001 não está ouvindo."
  echo "Verifique:"
  echo "  docker service ls"
  echo "  docker service logs $PORTAINER_AGENT_SERVICE_NAME"
fi

echo ""
echo "[Teste local 4] Validando redes overlay..."

PROXY_DRIVER="$(docker network inspect "$NETWORK_NAME" --format '{{.Driver}}' 2>/dev/null || echo missing)"
PUBLIC_DRIVER="$(docker network inspect "$PUBLIC_NETWORK_NAME" --format '{{.Driver}}' 2>/dev/null || echo missing)"

echo "$NETWORK_NAME: $PROXY_DRIVER"
echo "$PUBLIC_NETWORK_NAME: $PUBLIC_DRIVER"

if [ "$PROXY_DRIVER" != "overlay" ]; then
  echo "ERRO: rede '$NETWORK_NAME' não está como overlay."
fi

if [ "$PUBLIC_DRIVER" != "overlay" ]; then
  echo "ATENÇÃO: rede '$PUBLIC_NETWORK_NAME' não está como overlay."
  echo "Se ela já existir como bridge com containers ativos, o instalador não remove automaticamente."
fi

echo ""
echo "============================================================"
echo " ETAPA 6: DADOS DO PORTAINER SERVER PRINCIPAL"
echo "============================================================"
echo ""
echo "Agora informe os dados de acesso SSH ao servidor principal."
echo "O script vai entrar nele, detectar Portainer via Swarm ou Compose,"
echo "validar conexão com este Agent e, se você autorizou rotação,"
echo "aplicar o AGENT_SECRET no Portainer Server e nos Agents locais do principal."
echo ""

if [ -n "$MAIN_SERVER_IP" ]; then
  CONFIGURE_MAIN_DEFAULT="S"
else
  CONFIGURE_MAIN_DEFAULT="S"
fi

CONFIGURE_MAIN="$(ask_yes_no "Configurar/validar automaticamente o Portainer principal agora?" "$CONFIGURE_MAIN_DEFAULT")"

if [ "$CONFIGURE_MAIN" = "yes" ]; then
  if [ -z "$MAIN_SERVER_IP" ]; then
    MAIN_SERVER_IP="$(ask_required "IP do Portainer Server principal: ")"
  else
    MAIN_SERVER_IP="$(ask_default "IP do Portainer Server principal" "$MAIN_SERVER_IP")"
  fi

  MAIN_SSH_USER="$(ask_default "Usuário SSH do Portainer Server principal" "$MAIN_SSH_USER")"
  MAIN_SSH_PORT="$(ask_default "Porta SSH do Portainer Server principal" "$MAIN_SSH_PORT")"

  echo ""
  echo "Resumo da configuração do servidor principal:"
  echo "------------------------------------------------------------"
  echo "Portainer principal:     $MAIN_SERVER_IP"
  echo "SSH principal:           $MAIN_SSH_USER@$MAIN_SERVER_IP:$MAIN_SSH_PORT"
  echo "Servidor Agent:          $AGENT_PUBLIC_IP:9001"
  echo "Detecção Portainer:      automática"
  echo "Aplicar secret em:       $APPLY_SECRET_TO_MAIN"
  echo "------------------------------------------------------------"
  echo ""

  CONTINUE_MAIN="$(ask_yes_no "Continuar configuração do Portainer principal?" "S")"

  if [ "$CONTINUE_MAIN" = "yes" ]; then
    echo ""
    echo "============================================================"
    echo " ETAPA 7: LIBERANDO 9001 PARA O PORTAINER PRINCIPAL"
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
    echo " ETAPA 8: APLICANDO AGENT_SECRET NO PORTAINER PRINCIPAL"
    echo "============================================================"
    echo ""

    if [ "$APPLY_SECRET_TO_MAIN" = "yes" ]; then
      echo "Rotação autorizada: o AGENT_SECRET será aplicado no Portainer principal."

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
  echo "Procurando serviços Portainer Server e Portainer Agent..."

  PORTAINER_SERVER_SERVICES="$(docker service ls --format '{{.Name}} {{.Image}}' \
    | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee' \
    | awk '{print $1}')"

  PORTAINER_AGENT_SERVICES="$(docker service ls --format '{{.Name}} {{.Image}}' \
    | grep -E 'portainer/agent' \
    | awk '{print $1}')"

  if [ -z "$PORTAINER_SERVER_SERVICES" ]; then
    echo "ERRO: não foi possível encontrar serviço Portainer Server no Swarm."
    echo ""
    echo "Serviços existentes:"
    docker service ls
    exit 1
  fi

  echo ""
  echo "Serviços Portainer Server encontrados:"
  echo "$PORTAINER_SERVER_SERVICES"

  if [ -n "$PORTAINER_AGENT_SERVICES" ]; then
    echo ""
    echo "Serviços Portainer Agent encontrados:"
    echo "$PORTAINER_AGENT_SERVICES"
  else
    echo ""
    echo "Nenhum serviço Portainer Agent encontrado no Swarm principal."
  fi

  echo ""
  echo "Aplicando AGENT_SECRET nos serviços encontrados..."

  for service in $PORTAINER_SERVER_SERVICES $PORTAINER_AGENT_SERVICES; do
    echo ""
    echo "Atualizando serviço: $service"

    docker service update --env-rm AGENT_SECRET "$service" >/dev/null 2>&1 || true

    docker service update \
      --env-add AGENT_SECRET="$AGENT_SECRET" \
      "$service"
  done

  echo ""
  echo "Aguardando estabilização dos serviços..."
  sleep 8

  echo ""
  echo "Status dos serviços Portainer:"
  for service in $PORTAINER_SERVER_SERVICES $PORTAINER_AGENT_SERVICES; do
    docker service ps "$service" --no-trunc || true
  done

  echo ""
  echo "OK: AGENT_SECRET aplicado no Portainer Server e Agents do Swarm."
  exit 0
fi

echo ""
echo "Docker Swarm não está ativo."
echo "Tentando detectar instalação via Docker Compose..."

PORTAINER_CONTAINERS="$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' \
  | grep -E 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee|portainer/agent' \
  | awk '{print $1}')"

COMPOSE_FILE=""
COMPOSE_DIR=""
COMPOSE_SERVICES=""

if [ -n "$PORTAINER_CONTAINERS" ]; then
  echo "Containers Portainer encontrados:"
  echo "$PORTAINER_CONTAINERS"

  FIRST_CONTAINER="$(echo "$PORTAINER_CONTAINERS" | head -n 1)"

  COMPOSE_PROJECT="$(docker inspect "$FIRST_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
  COMPOSE_WORKDIR="$(docker inspect "$FIRST_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
  COMPOSE_FILES="$(docker inspect "$FIRST_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)"

  if [ -n "$COMPOSE_WORKDIR" ] && [ -n "$COMPOSE_FILES" ]; then
    FIRST_COMPOSE_FILE="$(echo "$COMPOSE_FILES" | cut -d',' -f1)"

    if [ -f "$FIRST_COMPOSE_FILE" ]; then
      COMPOSE_FILE="$FIRST_COMPOSE_FILE"
      COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
    elif [ -f "$COMPOSE_WORKDIR/$FIRST_COMPOSE_FILE" ]; then
      COMPOSE_FILE="$COMPOSE_WORKDIR/$FIRST_COMPOSE_FILE"
      COMPOSE_DIR="$COMPOSE_WORKDIR"
    fi

    for container in $PORTAINER_CONTAINERS; do
      SERVICE_NAME="$(docker inspect "$container" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"
      CONTAINER_PROJECT="$(docker inspect "$container" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"

      if [ -n "$SERVICE_NAME" ] && [ "$CONTAINER_PROJECT" = "$COMPOSE_PROJECT" ]; then
        COMPOSE_SERVICES="$COMPOSE_SERVICES $SERVICE_NAME"
      fi
    done
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
        if grep -qE 'portainer/portainer|portainer/portainer-ce|portainer/portainer-ee|portainer/agent' "$file"; then
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

if [ -z "$COMPOSE_SERVICES" ]; then
  echo "Detectando serviços pelo docker compose config..."

  if docker compose -f "$COMPOSE_NAME" config --services >/tmp/portainer_services.txt 2>/dev/null; then
    while read -r service; do
      if echo "$service" | grep -qiE 'portainer|agent'; then
        COMPOSE_SERVICES="$COMPOSE_SERVICES $service"
      fi
    done < /tmp/portainer_services.txt
  fi
fi

COMPOSE_SERVICES="$(echo "$COMPOSE_SERVICES" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"

if [ -z "$COMPOSE_SERVICES" ]; then
  echo "ERRO: não foi possível detectar serviços Portainer/Agent no Compose."
  echo ""
  echo "Serviços detectados:"
  cat /tmp/portainer_services.txt 2>/dev/null || true
  exit 1
fi

echo "Serviços Compose que receberão AGENT_SECRET:"
echo "$COMPOSE_SERVICES"

cat > docker-compose.agent-secret.yml <<EOF
services:
EOF

for service in $COMPOSE_SERVICES; do
  cat >> docker-compose.agent-secret.yml <<EOF
  $service:
    environment:
      AGENT_SECRET: "$AGENT_SECRET"
EOF
done

chmod 600 docker-compose.agent-secret.yml

echo "Arquivo docker-compose.agent-secret.yml criado:"
echo "  $COMPOSE_DIR/docker-compose.agent-secret.yml"
echo ""
echo "Aplicando configuração no Portainer Server e Agents..."

docker compose -f "$COMPOSE_NAME" -f docker-compose.agent-secret.yml up -d $COMPOSE_SERVICES

echo ""
echo "OK: AGENT_SECRET aplicado nos serviços Compose: $COMPOSE_SERVICES"
REMOTE_SCRIPT

      APPLY_SECRET_RESULT="$?"

      set -e

      if [ "$APPLY_SECRET_RESULT" = "0" ]; then
        echo ""
        echo "OK: AGENT_SECRET aplicado automaticamente no Portainer Server principal e Agents locais."
      else
        echo ""
        echo "ERRO: não foi possível aplicar automaticamente o AGENT_SECRET no Portainer Server principal."
        echo ""
        echo "O instalador continuará para os testes, mas talvez você precise verificar manualmente:"
        echo ""
        echo "  AGENT_SECRET=$AGENT_SECRET"
      fi
    else
      echo ""
      echo "Rotação não autorizada: mantendo o AGENT_SECRET atual do Portainer principal."
      echo "Isso é o comportamento correto para novas instalações."
      APPLY_SECRET_RESULT="0"
    fi

    echo ""
    echo "============================================================"
    echo " ETAPA 9: VALIDANDO CONEXÃO DO PRINCIPAL PARA O AGENT"
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
      echo "     docker service logs $PORTAINER_AGENT_SERVICE_NAME"
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
echo "Redes Swarm:"
echo "  $NETWORK_NAME"
echo "  $PUBLIC_NETWORK_NAME"
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
    echo "  OK: AGENT_SECRET aplicado automaticamente no Portainer Server e Agents."
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

echo "Serviços Swarm locais:"
docker service ls | grep -E "${TRAEFIK_STACK_NAME}_traefik|${PORTAINER_AGENT_SERVICE_NAME}" || true

echo ""
echo "Redes Docker:"
docker network ls | grep -E "${NETWORK_NAME}|${PUBLIC_NETWORK_NAME}|ingress" || true

echo ""
echo "Comandos úteis:"
echo "  docker service ls"
echo "  docker service logs -f $PORTAINER_AGENT_SERVICE_NAME"
echo "  docker service logs -f ${TRAEFIK_STACK_NAME}_traefik"
echo "  docker stack ps $TRAEFIK_STACK_NAME"
echo "  docker network ls"
echo ""
echo "Para ver o segredo depois:"
echo "  cat $AGENT_SECRET_FILE"
echo "============================================================"

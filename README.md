# Setup Portainer Agent + Traefik para Debian

Instalador automático para servidores Debian limpos com **Docker**, **Docker Compose Plugin**, **Traefik v3** e **Portainer Agent** protegido.

O objetivo deste projeto é facilitar a preparação de novos servidores Docker para serem gerenciados por um **Portainer Server principal**, com segurança, firewall, SSL e validação automática de conexão.

---

## O que este instalador faz

O `install.sh` automatiza:

- Instalação do Docker Engine
- Instalação do Docker Compose Plugin
- Criação da rede Docker `proxy`
- Instalação do Traefik v3
- Instalação do Portainer Agent
- Geração automática ou manual de `AGENT_SECRET`
- Proteção do Portainer Agent com `AGENT_SECRET`
- Configuração opcional do UFW
- Liberação da porta `9001` apenas para o IP do Portainer Server principal
- Suporte a SSL via:
  - HTTP Challenge
  - Cloudflare DNS Challenge
- Suporte a Cloudflare API Token
- Aplicação automática do `AGENT_SECRET` no Portainer Server principal
- Aplicação automática do mesmo `AGENT_SECRET` nos Portainer Agents já existentes no servidor principal
- Detecção automática de Docker Swarm ou Docker Compose no servidor principal
- Validação da conexão do servidor principal para o novo Agent
- Testes locais do container e da porta `9001`

---

## Fluxo da instalação

O instalador segue esta ordem:

1. Coleta os dados da instalação local.
2. Instala Docker, Docker Compose, Traefik e Portainer Agent.
3. Gera e salva o `AGENT_SECRET`.
4. Sobe a stack local do Traefik + Portainer Agent.
5. Configura o firewall local.
6. Testa se o Agent local está rodando.
7. Só depois pede os dados SSH do Portainer Server principal.
8. Acessa o servidor principal via SSH.
9. Detecta automaticamente se o Portainer principal usa Docker Swarm ou Docker Compose.
10. Aplica o `AGENT_SECRET` no Portainer Server principal.
11. Aplica o mesmo `AGENT_SECRET` nos Portainer Agents existentes.
12. Valida se o Portainer principal consegue acessar o novo Agent na porta `9001`.

---

## Requisitos

No servidor novo onde o Agent será instalado:

- Debian limpo
- Acesso root
- Conexão com a internet
- Portas `80`, `443` e `9001` disponíveis
- Acesso SSH ao Portainer Server principal

No servidor principal:

- Portainer Server já instalado
- Docker funcionando
- SSH acessível
- Permissão root ou usuário com acesso ao Docker

---

## Instalação rápida

Execute no servidor novo:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/GiroMidias/setup-portainer-agente/main/install.sh)

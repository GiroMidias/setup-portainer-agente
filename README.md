Instalador automático para Debian com Docker, Traefik v3 e Portainer Agent protegido por AGENT_SECRET, UFW e teste de conexão.

# Setup Traefik + Portainer Agent para Debian

Instalador automático para servidores Debian limpos com **Docker**, **Docker Compose Plugin**, **Traefik v3** e **Portainer Agent**.

Este setup foi criado para facilitar a preparação de novos servidores Docker gerenciados por um **Portainer Server principal**, usando uma instalação rápida via `bash`, com foco em segurança e praticidade.

## O que este instalador faz

- Instala Docker Engine
- Instala Docker Compose Plugin
- Cria a rede Docker `proxy`
- Instala e configura Traefik v3
- Instala e configura Portainer Agent
- Gera ou solicita um `AGENT_SECRET`
- Protege o Portainer Agent contra conexões não autorizadas
- Configura firewall UFW, se desejado
- Libera a porta `9001` somente para o IP do Portainer Server principal
- Mantém o Portainer Agent fora do Traefik
- Salva o segredo do Agent em arquivo protegido
- Testa se o Agent está rodando e se a porta `9001` está acessível

## Requisitos

- Servidor Debian limpo
- Acesso root ou sudo
- Conexão com a internet
- Um Portainer Server principal já instalado em outro servidor
- IP público do Portainer Server principal
- IP público do servidor onde o Agent será instalado

## Portas utilizadas

| Porta | Uso | Exposição recomendada |
|---:|---|---|
| `22` | SSH | Somente seu IP, se possível |
| `80` | HTTP / Let's Encrypt | Público |
| `443` | HTTPS / Traefik | Público |
| `9001` | Portainer Agent | Somente IP do Portainer Server principal |

## Instalação rápida

Execute no servidor novo onde deseja instalar o Traefik e o Portainer Agent:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/GiroMidias/setup-portainer-agente/main/install.sh)

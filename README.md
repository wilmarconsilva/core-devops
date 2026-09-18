# Core — Deploy em VPS

Stack completa: **PostgreSQL + API (.NET 10) + Web (Expo PWA) + Caddy (proxy reverso e TLS automático)**.

Este diretório é o *composition root de infraestrutura*: nenhuma das duas aplicações conhece o deploy da outra.
O `docker-compose.yml` referencia os repositórios como irmãos (isso vale para o build — na CI ou local;
no VPS de produção só este diretório é necessário, as imagens vêm do registry):

```
Core/
├── core-back-end/     # API .NET      (Docker/Dockerfile.Web.API.REST)
├── core-front-end/    # PWA Expo Web  (Docker/Dockerfile.Web)
└── core-deploy/       # este diretório (compose, Caddy/, .env, backup)
```

---

## 1. Topologia

```
                Internet (443/80)
                       │
              ┌────────▼────────┐
              │  proxy (Caddy)  │  TLS automático (Let's Encrypt)
              └───┬─────────┬───┘
       app.dominio│         │api.dominio
              ┌────▼────┐ ┌───▼────┐
              │ web-app │ │  api   │  (rede "edge")
              │  nginx  │ │ Kestrel│
              └─────────┘ └───┬────┘
                            │ (rede "data")
                      ┌─────▼──────┐
                      │  postgres  │  volume nomeado, sem porta publicada
                      └────────────┘
```

Decisões e por quê:

| Decisão | Motivo |
| --- | --- |
| **Caddy** como proxy | TLS + renovação automáticos em ~10 linhas de config; envia `X-Forwarded-Proto`, que o `Program.cs` já consome em Production (necessário para o cookie do refresh token sair com `Secure` / `SameSite=None`). |
| **Dois subdomínios** (`api.` e `app.`) | É a topologia que o código já assume: CORS configurável, `SameSite=None` quando HTTPS, Swagger no host da API. Front e API sobem e escalam de forma independente. A alternativa de domínio único (`/api`) está pronta e comentada no `Caddy/Caddyfile`. |
| **Front como estático em nginx** | `expo export -p web` gera site estático; não há motivo para manter Node em runtime. Imagem final pequena e sem superfície de servidor de aplicação. |
| **Duas redes** (`data` / `edge`) | O proxy e o `web-app` não têm rota até o banco. O Postgres não publica porta no host. |
| **Migrations no startup da API** | Já é o comportamento do `ApplyMigrationsAsync`. Por isso `depends_on: service_healthy` no Postgres. ⚠️ Não escale a API para mais de 1 réplica sem separar as migrations, ou duas instâncias competem pelo mesmo lock. |
| **Volume nomeado para `caddy-data`** | Guarda os certificados. Apagar esse volume repetidamente esbarra no *rate limit* do Let's Encrypt (5 duplicatas por semana). |

---

## 2. Requisitos do VPS

| Cenário | Mínimo recomendado |
| --- | --- |
| Produção — VPS só faz `pull` das imagens (§6) | 1–2 vCPU / **2 GB RAM** / 20 GB SSD |
| Build no próprio host (só no modo sem domínio, §8) | 2 vCPU / **4 GB RAM** / 40 GB SSD |

O deploy de produção não compila no VPS (§6), então 2 GB bastam. Já o build do .NET SDK e o do Expo
consomem cerca de 1,5–2 GB de RAM cada: se você buildar no próprio host, em VPS de 2 GB sem swap o
build **é morto pelo OOM killer** — adicione 2 GB de swap.

Software: Ubuntu 22.04/24.04 LTS + Docker Engine com Compose v2 **>= 2.24** (o overlay de registry usa `!reset`).

---

## 3. Preparação do host (uma vez)

```bash
# Docker Engine + Compose (script oficial)
curl -fsSL https://get.docker.com | sh

# Usuário não-root para operar a stack
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy

# Firewall: só SSH e HTTP(S) entram
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow OpenSSH && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
sudo ufw allow 443/udp   # HTTP/3
sudo ufw enable

# Atualizações de segurança automáticas
sudo apt install -y unattended-upgrades fail2ban

# (só se for buildar no próprio host) swap para sobreviver ao build
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
```

Endurecimento do SSH em `/etc/ssh/sshd_config`: `PermitRootLogin no` e `PasswordAuthentication no`.

---

## 4. DNS

Antes do primeiro `up`, crie os registros apontando para o IP do VPS — o Caddy só emite o certificado
depois que o desafio HTTP-01 resolver:

```
A    api.seudominio.com.br  ->  <IP do VPS>
A    app.seudominio.com.br  ->  <IP do VPS>
```

Se usar Cloudflare, mantenha o proxy **desligado (DNS only)** no primeiro start.

---

## 5. Build e publicação das imagens

As duas imagens vivem no GHCR (GitHub Container Registry), e é delas que o VPS puxa:

| Imagem | Contexto de build | Dockerfile |
| --- | --- | --- |
| `ghcr.io/<owner>/core-web-api-rest` | repositório do back-end | `Docker/Dockerfile.Web.API.REST` |
| `ghcr.io/<owner>/core-web-app` | repositório do front-end | `Docker/Dockerfile` |

`<owner>` é o dono do pacote no GitHub (o mesmo valor de `GHCR_OWNER` no `.env`) e **tem que estar
em minúsculas** — o GHCR rejeita maiúsculas no caminho da imagem. A tag é o que o VPS escolhe em
`IMAGE_TAG`.

Token: um PAT *classic* com escopo **`write:packages`** para publicar (e `read:packages`, que basta
no VPS). No GitHub Actions não precisa de PAT — o `GITHUB_TOKEN` do próprio job serve, desde que o
workflow declare `permissions: packages: write`.

> ⚠️ **A URL da API é embutida no bundle do front em tempo de build**, então ela é um `--build-arg`
> (`EXPO_PUBLIC_WEB_API_REST_URL`) e **não** uma variável de runtime: a imagem `core-web-app` fica
> atrelada ao ambiente. Publique tags distintas por ambiente (ex.: `core-web-app:prod-<sha>`) e nunca
> reaproveite a imagem de staging em produção.

### 5.1 Na máquina local via terminal

Rode a partir do diretório que contém os três
repositórios (`Core/`):

```bash
export GHCR_OWNER=wilmarconsilva     # minúsculas
export IMAGE_TAG=0.0.0
echo "$GHCR_TOKEN" | docker login ghcr.io -u $GHCR_OWNER --password-stdin

# API
docker build --platform linux/amd64 -f ../core-back-end/Docker/Dockerfile.Web.API.REST -t ghcr.io/$GHCR_OWNER/core-web-api-rest:1.1.0 -t ghcr.io/$GHCR_OWNER/core-web-api-rest:latest ../core-back-end

# Web — a URL da API é embutida agora, no build
docker build --platform linux/amd64 -f ../core-front-end/Docker/Dockerfile --build-arg EXPO_PUBLIC_WEB_API_REST_URL=https://cliente.core.api-rest.com.br -t ghcr.io/$GHCR_OWNER/core-web-app:1.1.0 -t ghcr.io/$GHCR_OWNER/core-web-app:latest ../core-front-end

docker push --all-tags ghcr.io/$GHCR_OWNER/core-web-api-rest
docker push --all-tags ghcr.io/$GHCR_OWNER/core-web-app
```

`--platform linux/amd64` não é opcional em Mac Apple Silicon ou em qualquer host ARM: sem ele a
imagem sai `arm64` e o VPS (x86) recusa com `exec format error`. Em host x86 o parâmetro é inócuo.

Conferir o que foi publicado:

```bash
docker buildx imagetools inspect ghcr.io/$GHCR_OWNER/core-web-api-rest:$IMAGE_TAG
```

### 5.2 Visibilidade do pacote

O primeiro push cria o pacote como **privado** — por isso o `docker login` no VPS (§6). Para
dispensar o login lá, abra o pacote em `github.com/users/<owner>/packages` → *Package settings* →
*Change visibility* → **Public**. Vale também vincular o pacote ao repositório na mesma tela, que é
o que faz a aba *Packages* aparecer no repo.

---

## 6. Deploy (imagens do registry)

O VPS **não compila**: com as imagens já publicadas (#5), ele apenas puxa e sobe. Isso mantém o
deploy independente do estado da máquina e da RAM disponível — o build do .NET SDK e o do Expo
consomem cerca de 1,5–2 GB de RAM cada.

```bash
sudo mkdir -p /opt/core && sudo chown deploy:deploy /opt/core
su - deploy
cd /opt/core

git clone https://github.com/<owner>/core-deploy.git    # ou copie este diretório
cd core-deploy

cp .env.example .env
openssl rand -base64 32   # -> POSTGRES_PASSWORD
openssl rand -base64 48   # -> JWT_SIGNING_KEY
nano .env                 # domínios, e-mail do ACME, SMTP, GHCR_OWNER, IMAGE_TAG

# GHCR: um token com escopo read:packages basta para puxar
echo "$GHCR_TOKEN" | docker login ghcr.io -u <usuario> --password-stdin

# o overlay do registry entra em todo comando da stack — um alias encurta
alias dc='docker compose -f docker-compose.yml -f docker-compose.registry.yml'

dc pull
dc up -d
dc logs -f web-api-rest    # acompanhe "Migrations aplicadas com sucesso."
```

O overlay `docker-compose.registry.yml` troca o `build` pelas imagens
`ghcr.io/${GHCR_OWNER}/core-web-api-rest` e `.../core-web-app` na tag de `IMAGE_TAG` (padrão
`latest`). Os repositórios das aplicações **não** precisam ser clonados no VPS — só este diretório.

Validação:

```bash
curl -fsS  https://api.seudominio.com.br/health   # {"status":"healthy"}
curl -fsSI https://app.seudominio.com.br/         # 200 + Cache-Control: no-cache
```

Migrando dados de um ambiente existente (ex.: Render) — gere o dump com um `pg_dump` de versão
igual ou superior à do banco de origem e restaure antes de expor a aplicação:

```bash
pg_dump "<connection-string-de-origem>" --format=plain --no-owner | gzip -9 > origem.sql.gz
gunzip -c origem.sql.gz | dc exec -T postgres psql -U core -d core
```

> ⚠️ Trocar de domínio **não** é operação de deploy: a URL da API está embutida no bundle do front
> (`EXPO_PUBLIC_WEB_API_REST_URL`, lido em `Application/Services/HttpClientService.ts`), fixada no
> build da imagem — é preciso publicar uma imagem nova (§5). Puxar a mesma tag e reiniciar o
> container não muda nada.

---

## 7. Operação

Com o `dc` da §6 no shell (`alias dc='docker compose -f docker-compose.yml -f docker-compose.registry.yml'`):

```bash
# Atualizar para uma versão nova publicada pela CI
cd /opt/core/core-deploy
nano .env        # IMAGE_TAG=<nova tag>, ou mantenha "latest"
dc pull && dc up -d

# Logs (json-file com rotação de 10 MB x 5 já configurada no compose)
dc logs -f web-api-rest
dc logs -f proxy

# Status e consumo
dc ps
docker stats --no-stream

# Acessar o banco (nunca exponha a porta 5432 na internet)
dc exec postgres psql -U core -d core

# Backup diário
./scripts/backup-db.sh
crontab -e   # 0 3 * * * cd /opt/core/core-deploy && ./scripts/backup-db.sh >> /var/log/core-backup.log 2>&1

# Restore
gunzip -c backups/core-20260101T030000Z.sql.gz | dc exec -T postgres psql -U core -d core

# Limpeza de imagens antigas (evita encher o disco)
docker image prune -af --filter "until=168h"
```

---

## 8. Rodando sem domínio (teste local ou VPS provisório)

Sem domínio o Caddy não consegue emitir certificado (Let's Encrypt exige DNS público) e o CORS
fixo em `https://${WEB_APP_DOMAIN}` não se aplica. Para isso existe o overlay `docker-compose.without-domain.yml`:
ele troca o Caddyfile por `Caddy/Caddyfile.without-domain` (HTTP puro, cada aplicação numa porta do
mesmo host — `:80` vai para o `web-app`, `:8080` vai para o `api`) e ajusta CORS/URL da API de acordo.
Como no compose base, **só o proxy publica portas**; `api` e `web-app` continuam apenas com `expose`.

```bash
cp .env.example .env
# preencha ao menos POSTGRES_PASSWORD e JWT_SIGNING_KEY (openssl rand ...);
# WEB_API_REST_DOMAIN/WEB_APP_DOMAIN podem ficar com o valor de exemplo, este overlay não os usa.

docker compose -f docker-compose.yml -f docker-compose.without-domain.yml up -d --build
```

- **Teste local (sua máquina)**: acesse `http://localhost/` (web-app) e `http://localhost:8080/health`
  (api). Não precisa mexer em `PUBLIC_HOST`.
- **VPS sem domínio ainda**: antes do `--build`, defina no `.env` `PUBLIC_HOST=<IP público do VPS>`
  — é isso que faz o front embutir a URL correta da API e o CORS liberar essa origem. Acesse
  `http://<IP>/`, e libere a porta da API no firewall (`sudo ufw allow 8080/tcp`).

A porta da API é configurável por `API_PORT` no `.env` (padrão 8080) — a mesma variável alimenta o
bloco do Caddy, a publicação de porta do proxy e a URL embutida no front, então não há como
divergirem. **A porta do web é fixa na 80** de propósito: o navegador omite a porta padrão no
header `Origin`, então `Cors__Origins__0` pode ser apenas `http://HOST`. Se o web saísse da 80, a
origem passaria a carregar a porta — e `http://HOST:80` **não** casa com o `http://HOST` que o
navegador envia.

Quando o domínio estiver pronto: pare a stack, apague `PUBLIC_HOST` do `.env`, preencha
`WEB_API_REST_DOMAIN`/`WEB_APP_DOMAIN`/`ACME_EMAIL` de verdade e suba de novo **sem o overlay `without-domain`**
(`docker compose -f docker-compose.yml -f docker-compose.registry.yml up -d`, como na §6) para
voltar a usar TLS automático.

> ⚠️ Assim como no fluxo com domínio, trocar `PUBLIC_HOST` depois de já ter buildado exige
> `docker compose -f docker-compose.yml -f docker-compose.without-domain.yml build web-app --no-cache` — a URL
> da API é embutida no bundle em tempo de build, reiniciar o container não muda nada.

### Por que porta, e não caminho único (`/api/*`)

Esta é a decisão de projeto do modo sem domínio, e ela existe por um motivo concreto.

A primeira versão servia tudo em `:80` e roteava por caminho, com `handle_path /api/*`. Só que o
`handle_path` remove o prefixo **na ida**: a API recebe `/authentication/refresh`, enquanto o
navegador continua enxergando `/api/authentication/refresh`. Requisições atravessam bem, mas
**qualquer caminho que o servidor devolva volta sem o `/api`** e deixa de casar do lado do cliente.
O caso concreto foi o cookie do refresh token: guardado sob `/authentication`, nunca enviado para
`/api/authentication/refresh` (RFC 6265 casa cookie por prefixo de caminho), e a sessão caindo a
cada F5 **mesmo com a API perfeitamente saudável**.

Separar por porta elimina a causa em vez de compensá-la — o caminho que a API enxerga volta a ser o
mesmo que o navegador vê. E funciona porque **porta não entra nem no escopo de cookie nem no
cálculo de *site***:

- o cookie posto por `HOST:8080` é guardado para o host `HOST` e reenviado para `HOST:8080`;
- `http://HOST` → `http://HOST:8080` é **same-site**, então o `SameSite=Lax` do modo HTTP é enviado
  inclusive em `POST`, que é o método do refresh.

O preço é o CORS voltar a existir, e isso é um ganho: em produção o front e a API também ficam em
origens distintas, então o modo por portas exercita o CORS que o roteamento por caminho mascarava.

> O gatilho daquele bug era a **reescrita de prefixo**, não a ausência de TLS — o casamento de
> `Path` é textual e não olha esquema, host nem porta. A alternativa de domínio único comentada no
> `Caddy/Caddyfile` tem exatamente o mesmo problema, sobre HTTPS; o aviso está lá.
>
> Não confunda com o outro efeito do HTTP em `AuthenticationController.cs`: `Secure` e
> `SameSite=None` só saem quando a requisição chega por HTTPS. Esse decide **quem** pode enviar o
> cookie (origem cross-site); o `Path` decide **para onde** ele é enviado. São independentes.

---

## 9. Pontos de atenção conhecidos

1. **`PORT` é obrigatório**: o `ENTRYPOINT` da imagem da API veio do Render (`--urls http://0.0.0.0:${PORT}`).
   O compose define `PORT=8080`; sem isso o Kestrel não sobe.
2. **Log em arquivo em Production**: o Serilog escreve em `Logs/*.txt` dentro do container (efêmero).
   Foi adicionado o sink de Console para que `docker logs` funcione; para retenção durável, prefira um
   agregador (Loki/Seq) a um volume de arquivo.
3. **Monitoramento externo**: aponte um uptime monitor (UptimeRobot, BetterStack) para
   `https://api.../health` e `https://app.../`. O VPS não avisa quando cai.

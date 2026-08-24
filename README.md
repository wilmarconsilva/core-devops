# Core — Deploy em VPS

Stack completa: **PostgreSQL + API (.NET 10) + Web (Expo PWA) + Caddy (proxy reverso e TLS automático)**.

Este diretório é o *composition root de infraestrutura*: nenhuma das duas aplicações conhece o deploy da outra.
O `docker-compose.yml` referencia os repositórios como irmãos:

```
Core/
├── core-back-end/     # API .NET      (Docker/Dockerfile.Web.Service.REST)
├── core-front-end/    # PWA Expo Web  (Docker/Dockerfile.Web)
└── core-deploy/       # este diretório (compose, Caddyfile, .env, backup)
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
              ┌───▼───┐ ┌───▼────┐
              │  web  │ │  api   │  (rede "edge")
              │ nginx │ │ Kestrel│
              └───────┘ └───┬────┘
                            │ (rede "data")
                      ┌─────▼──────┐
                      │  postgres  │  volume nomeado, sem porta publicada
                      └────────────┘
```

Decisões e por quê:

| Decisão | Motivo |
| --- | --- |
| **Caddy** como proxy | TLS + renovação automáticos em ~10 linhas de config; envia `X-Forwarded-Proto`, que o `Program.cs` já consome em Production (necessário para o cookie do refresh token sair com `Secure` / `SameSite=None`). |
| **Dois subdomínios** (`api.` e `app.`) | É a topologia que o código já assume: CORS configurável, `SameSite=None` quando HTTPS, Swagger no host da API. Front e API sobem e escalam de forma independente. A alternativa de domínio único (`/api`) está pronta e comentada no `Caddyfile`. |
| **Front como estático em nginx** | `expo export -p web` gera site estático; não há motivo para manter Node em runtime. Imagem final pequena e sem superfície de servidor de aplicação. |
| **Duas redes** (`data` / `edge`) | O proxy e o `web` não têm rota até o banco. O Postgres não publica porta no host. |
| **Migrations no startup da API** | Já é o comportamento do `ApplyMigrationsAsync`. Por isso `depends_on: service_healthy` no Postgres. ⚠️ Não escale a API para mais de 1 réplica sem separar as migrations, ou duas instâncias competem pelo mesmo lock. |
| **Volume nomeado para `caddy-data`** | Guarda os certificados. Apagar esse volume repetidamente esbarra no *rate limit* do Let's Encrypt (5 duplicatas por semana). |

---

## 2. Requisitos do VPS

| Cenário | Mínimo recomendado |
| --- | --- |
| Build **no VPS** (`up --build`) | 2 vCPU / **4 GB RAM** / 40 GB SSD |
| Build na **CI** + VPS só faz `pull` | 1–2 vCPU / **2 GB RAM** / 20 GB SSD |

O build do .NET SDK e o do Expo consomem cerca de 1,5–2 GB de RAM cada. Em VPS de 2 GB sem swap o build
**é morto pelo OOM killer** — use a opção da CI (§7) ou adicione 2 GB de swap.

Software: Ubuntu 22.04/24.04 LTS + Docker Engine com Compose v2 (>= 2.24 se usar o overlay de registry).

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

# (opcional, VPS de 2 GB) swap para sobreviver ao build
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

## 5. Primeiro deploy

```bash
sudo mkdir -p /opt/core && sudo chown deploy:deploy /opt/core
su - deploy
cd /opt/core

git clone https://github.com/<owner>/core-back-end.git
git clone https://github.com/wilmarconsilva/core-front-end.git
git clone https://github.com/<owner>/core-deploy.git    # ou copie este diretório

cd core-deploy
cp .env.example .env
openssl rand -base64 32   # -> POSTGRES_PASSWORD
openssl rand -base64 48   # -> JWT_SIGNING_KEY
nano .env                 # domínios, e-mail do ACME, SMTP

docker compose up -d --build
docker compose logs -f api    # acompanhe "Migrations aplicadas com sucesso."
```

Validação:

```bash
curl -fsS  https://api.seudominio.com.br/health   # {"status":"healthy"}
curl -fsSI https://app.seudominio.com.br/         # 200 + Cache-Control: no-cache
```

Migrando dados de um ambiente existente (ex.: Render) — gere o dump com um `pg_dump` de versão
igual ou superior à do banco de origem e restaure antes de expor a aplicação:

```bash
pg_dump "<connection-string-de-origem>" --format=plain --no-owner | gzip -9 > origem.sql.gz
gunzip -c origem.sql.gz | docker compose exec -T postgres psql -U core -d core
```

> ⚠️ **A URL da API é embutida no bundle do front em tempo de build**
> (`EXPO_PUBLIC_WEB_SERVICE_URL`, lido em `Application/Services/HttpClientService.ts`).
> Trocar de domínio exige `docker compose build web --no-cache && docker compose up -d web`;
> reiniciar o container não muda nada.

---

## 6. Operação

```bash
# Atualizar após um merge na main
cd /opt/core/core-back-end  && git pull
cd /opt/core/core-front-end && git pull
cd /opt/core/core-deploy    && docker compose up -d --build

# Logs (json-file com rotação de 10 MB x 5 já configurada no compose)
docker compose logs -f api
docker compose logs -f proxy

# Status e consumo
docker compose ps
docker stats --no-stream

# Acessar o banco (nunca exponha a porta 5432 na internet)
docker compose exec postgres psql -U core -d core

# Backup diário
./scripts/backup-db.sh
crontab -e   # 0 3 * * * cd /opt/core/core-deploy && ./scripts/backup-db.sh >> /var/log/core-backup.log 2>&1

# Restore
gunzip -c backups/core-20260101T030000Z.sql.gz | docker compose exec -T postgres psql -U core -d core

# Limpeza de imagens antigas (evita encher o disco)
docker image prune -af --filter "until=168h"
```

---

## 7. Evolução recomendada: build na CI, VPS só publica

Compilar no servidor de produção é o maior risco desta configuração: consome a RAM que a aplicação
está usando e deixa o deploy sujeito ao estado da máquina. O caminho natural é build no GitHub
Actions, publicação no GHCR e `pull` no VPS:

```bash
# no VPS, depois de configurar GHCR_OWNER e IMAGE_TAG no .env
echo "$GHCR_TOKEN" | docker login ghcr.io -u <usuario> --password-stdin
docker compose -f docker-compose.yml -f docker-compose.registry.yml pull
docker compose -f docker-compose.yml -f docker-compose.registry.yml up -d
```

Nesse cenário o `EXPO_PUBLIC_WEB_SERVICE_URL` passa a ser um `--build-arg` do workflow — a imagem
`core-web` fica atrelada ao ambiente, então publique tags distintas por ambiente
(ex.: `core-web:prod-<sha>`).

---

## 8. Pontos de atenção conhecidos

1. **Health check do container da API**: `mcr.microsoft.com/dotnet/aspnet:10.0` não traz `curl`/`wget`,
   por isso o serviço `api` não define `healthcheck`. Para habilitar, acrescente na etapa final do
   `Dockerfile.Web.Service.REST`, antes do `USER app`:
   `RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*`
   e no compose: `test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/health"]`.
2. **`PORT` é obrigatório**: o `ENTRYPOINT` da imagem da API veio do Render (`--urls http://0.0.0.0:${PORT}`).
   O compose define `PORT=8080`; sem isso o Kestrel não sobe.
3. **`core-back-end/Docker/.dockerignore` não é lido pelo Docker** — vale o `.dockerignore` na raiz do
   contexto (criado neste ajuste) ou `Docker/Dockerfile.Web.Service.REST.dockerignore`. Sem o da raiz, o
   contexto de build incluía `Presentation/Web/Application/node_modules` (centenas de MB por build).
4. **Log em arquivo em Production**: o Serilog escreve em `Logs/*.txt` dentro do container (efêmero).
   Foi adicionado o sink de Console para que `docker logs` funcione; para retenção durável, prefira um
   agregador (Loki/Seq) a um volume de arquivo.
5. **Monitoramento externo**: aponte um uptime monitor (UptimeRobot, BetterStack) para
   `https://api.../health` e `https://app.../`. O VPS não avisa quando cai.

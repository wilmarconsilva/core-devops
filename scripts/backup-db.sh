#!/usr/bin/env bash
# Backup lógico do PostgreSQL da stack Core.
#
# Uso:   ./scripts/backup-db.sh [diretorio-destino]
# Cron:  0 3 * * * cd /opt/core/core-deploy && ./scripts/backup-db.sh >> /var/log/core-backup.log 2>&1
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${1:-${DEPLOY_DIR}/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

cd "${DEPLOY_DIR}"
# shellcheck disable=SC1091
set -a; source .env; set +a

mkdir -p "${BACKUP_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILE="${BACKUP_DIR}/${POSTGRES_DB}-${STAMP}.sql.gz"

echo "[$(date -uIs)] Gerando backup em ${FILE}"
docker compose exec -T postgres \
  pg_dump --username="${POSTGRES_USER}" --dbname="${POSTGRES_DB}" --format=plain --no-owner \
  | gzip -9 > "${FILE}"

# Falha explicitamente se o dump saiu vazio/corrompido.
gzip -t "${FILE}"
echo "[$(date -uIs)] Backup concluído: $(du -h "${FILE}" | cut -f1)"

find "${BACKUP_DIR}" -name "${POSTGRES_DB}-*.sql.gz" -mtime "+${RETENTION_DAYS}" -delete
echo "[$(date -uIs)] Backups com mais de ${RETENTION_DAYS} dias removidos"

# IMPORTANTE: backup no mesmo VPS não é backup. Replique para fora (rclone/S3/Backblaze).

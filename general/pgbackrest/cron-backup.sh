#!/usr/bin/env bash
set -Eeuo pipefail

# Đường dẫn log và file lock để tránh backup chồng chéo
LOG_FILE="/var/log/pgbackrest/backup.log"
LOCK_FILE="/tmp/pgbackrest-backup.lock"

# --- Cấu hình MinIO (bật/tắt và thông tin kết nối) ---
MINIO_ENABLED=false
MINIO_ENDPOINT=http://100.85.22.67:9001
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin
MINIO_BUCKET=pgbackrest-backup

# --- Cấu hình NetBackup (bật/tắt và thông tin kết nối) ---
NETBACKUP_ENABLED=false
NETBACKUP_POLICY=PostgreSQL_Backup
NETBACKUP_CLIENT=$(hostname)
NETBACKUP_SERVER=netbackup-master
PG_BACKUP_REPO=/var/lib/pgbackrest

# --- Lock file: đảm bảo chỉ 1 tiến trình backup chạy tại 1 thời điểm ---
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date): Another backup is already running" >> "$LOG_FILE"
    exit 1
fi

# --- Kiểm tra PostgreSQL có sẵn sàng nhận kết nối không ---
if ! pg_isready -q; then
    echo "$(date): PostgreSQL is not ready" >> "$LOG_FILE"
    exit 1
fi

# --- Chọn node backup: ưu tiên sync standby, fallback sang replica lag thấp nhất ---
if [[ "$(psql -XAtqc 'SELECT pg_is_in_recovery()')" != "t" ]]; then
    echo "$(date): This is primary, skipping" >> "$LOG_FILE"
    exit 0
fi

primary_host=$(psql -XAtqc "SELECT sender_host FROM pg_stat_wal_receiver LIMIT 1")
primary_port=$(psql -XAtqc "SELECT sender_port FROM pg_stat_wal_receiver LIMIT 1")
my_ip=$(hostname -I | awk '{print $1}')

sync_count=$(psql -XAtqc "SELECT count(*) FROM pg_stat_replication WHERE sync_state = 'sync'" \
    -h "$primary_host" -p "${primary_port:-5432}")

if [[ "$sync_count" -gt 0 ]]; then
    is_sync=$(psql -XAtqc "SELECT count(*) FROM pg_stat_replication WHERE client_addr = '$my_ip' AND sync_state = 'sync'" \
        -h "$primary_host" -p "${primary_port:-5432}")
    if [[ "$is_sync" -eq 0 ]]; then
        echo "$(date): Not sync standby, skipping" >> "$LOG_FILE"
        exit 0
    fi
    echo "$(date): Running on sync standby ($my_ip)" >> "$LOG_FILE"
else
    my_lag=$(psql -XAtqc "SELECT extract(epoch from replay_lag) FROM pg_stat_replication WHERE client_addr = '$my_ip'" \
        -h "$primary_host" -p "${primary_port:-5432}")
    if [[ -z "$my_lag" ]]; then
        echo "$(date): Cannot determine replication lag, skipping" >> "$LOG_FILE"
        exit 0
    fi
    min_lag=$(psql -XAtqc "SELECT min(extract(epoch from replay_lag)) FROM pg_stat_replication" \
        -h "$primary_host" -p "${primary_port:-5432}")
    if [[ -z "$min_lag" ]]; then
        echo "$(date): No replicas found on primary, skipping" >> "$LOG_FILE"
        exit 0
    fi
    if awk "BEGIN {exit !($my_lag > $min_lag)}"; then
        echo "$(date): Not the lowest-lag replica (lag=${my_lag}s), skipping" >> "$LOG_FILE"
        exit 0
    fi
    echo "$(date): Running on lowest-lag replica ($my_ip, lag=${my_lag}s)" >> "$LOG_FILE"
fi

echo "$(date): Starting backup" >> "$LOG_FILE"

# --- Thực hiện backup full và ghi log chi tiết ---
# if sudo -u postgres pgbackrest backup --stanza=cluster_1 --type=full --log-level-console=info >> "$LOG_FILE" 2>&1; then
#     echo "$(date): Backup completed successfully" >> "$LOG_FILE"
# else
#     echo "$(date): Backup failed with exit code $?" >> "$LOG_FILE"
#     exit 1
# fi
if sudo -u postgres pgbackrest backup \
    --stanza=cluster_1 \
    --type=full \
    --log-level-console=info >> "$LOG_FILE" 2>&1
then
    echo "$(date): Backup completed successfully" >> "$LOG_FILE"
else
    rc=$?
    echo "$(date): Backup failed with exit code $rc" >> "$LOG_FILE"
    exit "$rc"
fi

# --- Xóa các backup cũ theo chính sách lưu trữ đã cấu hình ---
echo "$(date): Cleaning old backups" >> "$LOG_FILE"
sudo -u postgres pgbackrest expire --stanza=cluster_1 --log-level-console=info >> "$LOG_FILE" 2>&1

# --- Đẩy repository pgbackrest lên MinIO nếu được bật ---
if [[ "$MINIO_ENABLED" == "true" ]]; then
    echo "$(date): Pushing pgbackrest repository to MinIO" >> "$LOG_FILE"
    if command -v mc &>/dev/null; then
        if ! mc alias list pgbackup &>/dev/null; then
            mc alias set pgbackup "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"
        fi
        mc mirror "$PG_BACKUP_REPO" "pgbackup/$MINIO_BUCKET" >> "$LOG_FILE" 2>&1
        echo "$(date): Repository pushed to MinIO successfully" >> "$LOG_FILE"
    elif command -v aws &>/dev/null; then
        export AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"
        aws --endpoint-url "$MINIO_ENDPOINT" s3 sync "$PG_BACKUP_REPO" "s3://$MINIO_BUCKET" >> "$LOG_FILE" 2>&1
        echo "$(date): Repository pushed to MinIO via aws cli successfully" >> "$LOG_FILE"
    else
        echo "$(date): MinIO client tools (mc or aws) not found" >> "$LOG_FILE"
        exit 1
    fi
fi

# --- Đẩy repository pgbackrest lên NetBackup nếu được bật ---
if [[ "$NETBACKUP_ENABLED" == "true" ]]; then
    echo "$(date): Pushing pgbackrest repository to NetBackup" >> "$LOG_FILE"
    if command -v nbbackup &>/dev/null; then
        nbbackup -policy "$NETBACKUP_POLICY" -client "$NETBACKUP_CLIENT" -server "$NETBACKUP_SERVER" -source "$PG_BACKUP_REPO" >> "$LOG_FILE" 2>&1
        echo "$(date): Repository pushed to NetBackup successfully" >> "$LOG_FILE"
    elif command -v bpcd &>/dev/null; then
        tar -cf - -C "$PG_BACKUP_REPO" . | bpcd -client "$NETBACKUP_CLIENT" -policy "$NETBACKUP_POLICY" >> "$LOG_FILE" 2>&1
        echo "$(date): Repository pushed to NetBackup via bpcd successfully" >> "$LOG_FILE"
    else
        echo "$(date): NetBackup client tools (nbbackup or bpcd) not found" >> "$LOG_FILE"
        exit 1
    fi
fi

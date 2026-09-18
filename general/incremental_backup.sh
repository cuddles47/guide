#!/usr/bin/env bash
set -Eeuo pipefail

# --- Cấu hình kết nối PostgreSQL và backup ---
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=backup
PGPASSWORD=change-me
BACKUP_ROOT=/var/backups/postgresql/cluster_1
BACKUP_RETENTION_DAYS=30

# --- Đặt umask 077 để đảm bảo file backup chỉ owner mới đọc được ---
umask 077
LOCK_FILE="$BACKUP_ROOT/.backup.lock"
mkdir -p "$BACKUP_ROOT"

# --- Lock file: ngăn nhiều tiến trình backup chạy đồng thời ---
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    printf 'Another backup is already running.\n' >&2
    exit 1
fi

# --- Kiểm tra PostgreSQL có sẵn sàng nhận kết nối không ---
if ! pg_isready -q -h "$PGHOST" -p "$PGPORT" -U "$PGUSER"; then
    printf 'PostgreSQL is not ready at %s:%s.\n' "$PGHOST" "$PGPORT" >&2
    exit 1
fi

# --- Chọn node backup: ưu tiên sync standby, fallback sang replica lag thấp nhất ---
if [[ "$(psql -XAtqc 'SELECT pg_is_in_recovery()')" != "t" ]]; then
    printf 'This is primary, skipping backup.\n' >&2
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
        printf 'Not sync standby, skipping.\n' >&2
        exit 0
    fi
    printf 'Running on sync standby (%s).\n' "$my_ip" >&2
else
    my_lag=$(psql -XAtqc "SELECT extract(epoch from replay_lag) FROM pg_stat_replication WHERE client_addr = '$my_ip'" \
        -h "$primary_host" -p "${primary_port:-5432}")
    if [[ -z "$my_lag" ]]; then
        printf 'Cannot determine replication lag, skipping.\n' >&2
        exit 0
    fi
    min_lag=$(psql -XAtqc "SELECT min(extract(epoch from replay_lag)) FROM pg_stat_replication" \
        -h "$primary_host" -p "${primary_port:-5432}")
    if [[ -z "$min_lag" ]]; then
        printf 'No replicas found on primary, skipping.\n' >&2
        exit 0
    fi
    if awk "BEGIN {exit !($my_lag > $min_lag)}"; then
        printf 'Not the lowest-lag replica (lag=%ss), skipping.\n' "$my_lag" >&2
        exit 0
    fi
    printf 'Running on lowest-lag replica (%s, lag=%ss).\n' "$my_ip" "$my_lag" >&2
fi

# --- Tìm backup_manifest mới nhất để backup incremental (nếu có) ---
latest_manifest="$(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type f -name backup_manifest -printf '%T@ %p\n' | sort -nr | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }')"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$BACKUP_ROOT/$timestamp"
mkdir "$backup_dir"

# --- Cleanup: xóa thư mục backup nếu quá trình backup bị lỗi ---
cleanup() {
    if [[ "$?" -ne 0 ]]; then
        rm -rf "$backup_dir"
    fi
}
trap cleanup EXIT

# --- Thiết lập tham số cho pg_basebackup ---
backup_args=(
    --pgdata="$backup_dir"
    --host="$PGHOST"
    --port="$PGPORT"
    --username="$PGUSER"
    --format=plain
    --write-recovery-conf
    --checkpoint=fast
    --manifest-checksums
    --progress
)

# --- Nếu có manifest cũ thì backup incremental, ngược lại backup full ---
if [[ -n "$latest_manifest" ]]; then
    backup_args+=(--incremental="$latest_manifest")
    printf 'Starting incremental backup: %s\n' "$backup_dir"
else
    printf 'No previous manifest found; starting full baseline backup: %s\n' "$backup_dir"
fi

# --- Thực hiện backup bằng pg_basebackup ---
pg_basebackup "${backup_args[@]}"
printf 'Backup completed: %s\n' "$backup_dir"

# --- Xóa các backup cũ hơn số ngày lưu trữ (retention policy) ---
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf -- {} +
trap - EXIT
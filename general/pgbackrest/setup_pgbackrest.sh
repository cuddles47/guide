#!/usr/bin/env bash
set -Eeuo pipefail

# Lấy đường dẫn thư mục chứa script để tìm file config đi kèm
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/pgbackrest.conf"

# Yêu cầu quyền root để cài đặt và cấu hình hệ thống
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# --- Cài đặt pgBackRest (bỏ qua nếu đã có) ---
echo "=== Installing pgBackRest ==="
if command -v pgbackrest &>/dev/null; then
    echo "pgBackRest already installed: $(pgbackrest version)"
else
    apt-get update
    apt-get install -y pgbackrest
fi

# --- Tạo thư mục config/log/spool và phân quyền cho postgres ---
echo "=== Configuring pgBackRest ==="
mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest /var/lib/pgbackrest
chown postgres:postgres /var/log/pgbackrest /var/spool/pgbackrest /var/lib/pgbackrest
chmod 750 /var/log/pgbackrest /var/spool/pgbackrest /var/lib/pgbackrest

cp "$CONFIG_FILE" /etc/pgbackrest/pgbackrest.conf
chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
chmod 640 /etc/pgbackrest/pgbackrest.conf

# --- Tạo SSH key cho user postgres để giao tiếp giữa các node cluster ---
echo "=== Setting up SSH keys for postgres user ==="
if [[ ! -f /var/lib/postgresql/.ssh/id_rsa ]]; then
    sudo -u postgres ssh-keygen -t rsa -b 4096 -f /var/lib/postgresql/.ssh/id_rsa -N "" -q
fi

echo "Distribute this public key to all cluster nodes:"
echo "sudo -u postgres cat /var/lib/postgresql/.ssh/id_rsa.pub"
echo "Then add to /var/lib/postgresql/.ssh/authorized_keys on each node"

# --- Khởi tạo stanza (đơn vị quản lý backup) cho cluster ---
echo "=== Initializing pgBackRest repository ==="
sudo -u postgres pgbackrest stanza-create --stanza=cluster_1 --no-online

# --- Kiểm tra cấu hình đã đúng chưa (WAL, archive, kết nối...) ---
echo "=== Verifying configuration ==="
sudo -u postgres pgbackrest check --stanza=cluster_1

echo "=== Setup complete ==="
echo "Next steps:"
echo "1. Update patroni.yaml on all nodes to enable WAL archiving"
echo "2. Reload Patroni configuration"
echo "3. Run initial backup: sudo -u postgres pgbackrest backup --stanza=cluster_1 --type=full"
echo "4. Setup cron job for automated backups"

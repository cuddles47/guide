# Hướng dẫn cài đặt pgBackRest

## Tổng quan
Giải pháp backup tự động sử dụng pgBackRest với MinIO (S3-compatible).

**Cấu hình MinIO:**
- Endpoint: http://100.85.22.67:9001
- Bucket: pgbackrest-backup
- Access Key: minioadmin

## Cài đặt nhanh

### 1. Chạy script cài đặt trên tất cả nodes
```bash
sudo ./setup_pgbackrest.sh
```

### 2. Thiết lập SSH keys (trên mỗi node)
```bash
sudo -u postgres cat /var/lib/postgresql/.ssh/id_rsa.pub
```
Thêm public key vào `/var/lib/postgresql/.ssh/authorized_keys` trên tất cả các node trong cluster.

### 3. Cập nhật cấu hình Patroni
Chỉnh sửa `patroni.yaml` trên tất cả các node và cập nhật các tham số:

```yaml
postgresql:
  parameters:
    archive_mode: on
    archive_command: 'pgbackrest --stanza=cluster_1 archive-push %p'
    restore_command: 'pgbackrest --stanza=cluster_1 archive-get %f "%p"'
```

### 4. Reload Patroni
```bash
patronictl reload /etc/patroni/patroni.yaml
```

### 5. Chạy backup full lần đầu
```bash
sudo -u postgres pgbackrest backup --stanza=cluster_1 --type=full
```

### 6. Thiết lập backup tự động
```bash
install -o postgres -g postgres -m 750 cron-backup.sh /usr/local/sbin/pgbackrest-backup.sh
```

Thêm vào crontab của user postgres:
```cron
0 2 * * * /usr/local/sbin/pgbackrest-backup.sh
```

Script sẽ ưu tiên chạy trên sync standby. Nếu không có sync standby, nó sẽ chạy trên replica có lag thấp nhất. Script bỏ qua primary và các replica có lag cao hơn.

### 7. Tích hợp MinIO (tùy chọn)

Để đẩy backup lên MinIO (S3-compatible), chỉnh sửa `cron-backup.sh`:

```bash
MINIO_ENABLED=true
MINIO_ENDPOINT=http://100.85.22.67:9001
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin123
MINIO_BUCKET=pgbackrest-backup
```

Script sẽ sử dụng `mc` (MinIO Client) hoặc `aws` CLI (tùy tool có sẵn) để sync repository pgbackrest lên MinIO sau khi backup hoàn tất.

### 8. Tích hợp NetBackup (tùy chọn)

Để đẩy backup lên Veritas NetBackup, chỉnh sửa `cron-backup.sh`:

```bash
NETBACKUP_ENABLED=true
NETBACKUP_POLICY=PostgreSQL_Backup
NETBACKUP_CLIENT=$(hostname)
NETBACKUP_SERVER=netbackup-master
PG_BACKUP_REPO=/var/lib/pgbackrest
```

Script sẽ sử dụng `nbbackup` hoặc `bpcd` (tùy tool có sẵn) để đẩy repository pgbackrest lên NetBackup sau khi backup hoàn tất.

## Các thao tác thường dùng

### Backup thủ công
```bash
sudo -u postgres pgbackrest backup --stanza=cluster_1 --type=full
sudo -u postgres pgbackrest backup --stanza=cluster_1 --type=diff
sudo -u postgres pgbackrest backup --stanza=cluster_1 --type=incr
```

### Liệt kê backups
```bash
sudo -u postgres pgbackrest info --stanza=cluster_1
```

### Restore từ backup
```bash
sudo systemctl stop patroni
sudo -u postgres pgbackrest restore --stanza=cluster_1 --delta
sudo systemctl start patroni
```

### Point-in-time recovery (PITR)
```bash
sudo -u postgres pgbackrest restore --stanza=cluster_1 --type=time --target="2024-01-15 10:00:00"
```

### Kiểm tra trạng thái repository
```bash
sudo -u postgres pgbackrest check --stanza=cluster_1
```

## Chính sách lưu trữ
- Full backups: giữ lại 4 bản
- Differential backups: giữ lại 7 bản
- Các backup cũ tự động bị xóa sau mỗi lần backup

## Xử lý sự cố

### Xem logs
```bash
tail -f /var/log/pgbackrest/backup.log
sudo -u postgres pgbackrest backup --stanza=cluster_1 --type=full --log-level-console=debug
```

### Kiểm tra kết nối SSH
```bash
sudo -u postgres ssh postgres@192.168.1.156 "echo OK"
```

### Kiểm tra kết nối MinIO
```bash
curl http://100.85.22.67:9001/minio/health/live
```

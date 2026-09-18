# Hướng dẫn nhanh pgBackRest

## Các files đã tạo
- `pgbackrest.conf` - Cấu hình pgBackRest với MinIO
- `setup_pgbackrest.sh` - Script cài đặt tự động
- `cron-backup.sh` - Script backup tự động
- `README.md` - Tài liệu đầy đủ

## Các bước triển khai

### Bước 1: Chạy setup trên cả 3 nodes
```bash
cd /home/devops/guide/general/pgbackrest
sudo ./setup_pgbackrest.sh
```

### Bước 2: Thiết lập SSH keys giữa các nodes
Trên mỗi node, chạy:
```bash
sudo -u postgres cat /var/lib/postgresql/.ssh/id_rsa.pub
```
Thêm output vào `/var/lib/postgresql/.ssh/authorized_keys` trên TẤT CẢ các nodes (155, 156, 157).

### Bước 3: Deploy các file patroni.yaml đã cập nhật
Copy patroni.yaml đã cập nhật lên mỗi node:
- Node 1 (192.168.1.155): `/home/devops/guide/node 1/patroni.yaml`
- Node 2 (192.168.1.156): `/home/devops/guide/node2/patroni.yaml`
- Node 3 (192.168.1.157): `/home/devops/guide/node3/patroni.yaml`

### Bước 4: Reload Patroni trên tất cả nodes
```bash
patronictl reload /etc/patroni/patroni.yaml
```

### Bước 5: Chạy backup đầu tiên từ node primary
```bash
sudo -u postgres pgbackrest backup --stanza=cluster_1 --type=full
```

### Bước 6: Thiết lập cron job trên node primary
```bash
sudo install -o postgres -g postgres -m 750 cron-backup.sh /usr/local/sbin/pgbackrest-backup.sh
sudo -u postgres crontab -e
# Thêm dòng: 0 2 * * * /usr/local/sbin/pgbackrest-backup.sh
```

## Kiểm tra
```bash
sudo -u postgres pgbackrest info --stanza=cluster_1
sudo -u postgres pgbackrest check --stanza=cluster_1
```

## Tóm tắt cấu hình
- **MinIO**: http://100.85.22.67:9001
- **Bucket**: pgbackrest-backup
- **Lưu trữ**: 4 full backups, 7 diff backups
- **Lịch backup**: Hàng ngày lúc 2:00 sáng
- **Archive**: WAL files tự động archive lên MinIO

## Lưu ý quan trọng
- Script `setup_pgbackrest.sh` cần chạy với quyền root
- Script `cron-backup.sh` chỉ chạy backup trên node primary (tự động kiểm tra)
- WAL archiving được bật trên tất cả nodes để đảm bảo PITR
- Backup được lưu trên MinIO, có thể restore từ bất kỳ node nào

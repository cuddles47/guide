# PostgreSQL Backup với pgBackRest

## 1. Mục tiêu

Thiết lập backup PostgreSQL bằng pgBackRest với lịch:

- **Full backup:** Thứ 7 lúc 02:00.
- **Incremental backup:** Thứ 2–Thứ 6, mỗi 6 giờ.
- Không sử dụng Differential backup.
- pgBackRest tự quản lý backup chain và dependency giữa Full → Incremental.

---

## 2. Lịch backup

### Full backup

```cron
0 2 * * 6 pgbackrest --stanza=cluster_1 --type=full backup
```

Chạy:

```text
Thứ 7 02:00
```

### Incremental backup

```cron
0 */6 * * 1-5 pgbackrest --stanza=cluster_1 --type=incr backup
```

Chạy từ Thứ 2 đến Thứ 6 vào:

```text
00:00
06:00
12:00
18:00
```

### Differential backup

Hiện tại không sử dụng:

```cron
#0 2 * * 1-5 pgbackrest --stanza=cluster_1 --type=diff backup
```

---

## 3. Kiểm tra trạng thái pgBackRest

### Kiểm tra stanza

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 check
```

Mục đích:

- Kiểm tra repository.
- Kiểm tra WAL archive.
- Kiểm tra cấu hình pgBackRest.
- Xác nhận PostgreSQL có thể archive WAL tới repository.

Kết quả mong muốn:

```text
check repo configuration ... ok
check archive configuration ... ok
check command end: completed successfully
```

### Xem danh sách backup

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 info
```

Xem dạng JSON:

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 info --output=json
```

---

## 4. Ví dụ trạng thái backup

Ví dụ:

```text
stanza: cluster_1
    status: ok

    full backup: 20260925-040344F
        timestamp start/stop:
            2026-09-25 04:03:44+07 /
            2026-09-25 04:04:10+07

        database size: 130.5MB
        database backup size: 130.5MB

        repo1:
            backup set size: 26.4MB
            backup size: 26.4MB

    incr backup: 20260925-040344F_20260925-045357I
        timestamp start/stop:
            2026-09-25 04:53:57+07 /
            2026-09-25 04:53:59+07

        database size: 130.5MB
        database backup size: 8.3KB

        repo1:
            backup set size: 26.4MB
            backup size: 409B

        backup reference total: 1 full
```

Điều này cho thấy:

```text
FULL
  │
  └── INCR
```

Incremental:

```text
20260925-040344F_20260925-045357I
```

đang reference tới Full:

```text
20260925-040344F
```

`backup reference total: 1 full` cho biết incremental này thuộc backup chain của Full đó.

---

## 5. Hiểu cơ chế Full / Diff / Incr

### Full

Full backup tạo một backup set đầy đủ của database tại thời điểm backup.

Ví dụ:

```text
FULL F1
```

### Differential

Differential backup chứa các thay đổi kể từ **Full gần nhất**.

Ví dụ:

```text
F1
 ├── DIFF1
 ├── DIFF2
 └── DIFF3
```

Mỗi DIFF đều dựa trên Full F1.

### Incremental

Incremental backup chỉ chứa các thay đổi kể từ backup gần nhất trong chain.

Ví dụ:

```text
F1
 └── INCR1
      └── INCR2
           └── INCR3
```

pgBackRest tự quản lý dependency giữa các backup.

**Không cần tự viết script để ghép Full + Incremental khi restore.**

---

## 6. Luồng backup hiện tại

Với cron hiện tại:

```text
                    FULL
              Thứ 7 02:00
                    │
                    ├── INCR
                    │   T2 00:00
                    │
                    ├── INCR
                    │   T2 06:00
                    │
                    ├── INCR
                    │   T2 12:00
                    │
                    ├── INCR
                    │   T2 18:00
                    │
                    ├── ...
                    │
                    └── INCR
                        T6 18:00
                              │
                              ▼
                    FULL tiếp theo
                    Thứ 7 02:00
```

pgBackRest tự quản lý chain này.

---

## 7. Kiểm tra cron

Nếu sử dụng crontab của user `postgres`:

```bash
crontab -u postgres -l
```

Hoặc:

```bash
sudo -u postgres crontab -l
```

Kiểm tra pgBackRest:

```bash
which pgbackrest
pgbackrest version
```

---

## 8. Kiểm tra cấu hình repository và retention

Kiểm tra các cấu hình liên quan:

```bash
grep -nE 'repo1-retention|repo1-path|archive-' /etc/pgbackrest/pgbackrest.conf
```

Ví dụ retention:

```ini
repo1-retention-full=4
```

Ý nghĩa:

```text
Giữ lại 4 Full backup
```

pgBackRest sẽ quản lý các backup phụ thuộc vào những Full backup còn được giữ.

Không nên tự xóa thư mục backup trực tiếp trong repository.

---

## 9. Kiểm tra WAL archive

Xem WAL archive min/max:

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 info
```

Ví dụ:

```text
wal archive min/max (18):
0000000100000000000000A0 /
0000000100000000000000A5
```

Kiểm tra PostgreSQL:

```sql
SHOW archive_mode;
SHOW archive_command;
```

Kiểm tra trạng thái archive:

```sql
SELECT *
FROM pg_stat_archiver;
```

Các thông tin cần quan tâm:

```text
archived_count
failed_count
last_archived_wal
last_archived_time
last_failed_wal
last_failed_time
```

---

## 10. Test incremental backup

Sau khi Full backup hoàn thành, có thể tạo dữ liệu/thay đổi dữ liệu để kiểm tra Incremental thực sự bắt được thay đổi.

Chạy:

```bash
sudo -u postgres pgbackrest \
  --stanza=cluster_1 \
  --type=incr \
  backup
```

Sau đó:

```bash
sudo -u postgres pgbackrest \
  --stanza=cluster_1 \
  info
```

Kiểm tra:

```text
database backup size
repo1 backup size
```

Nếu database gần như không thay đổi, Incremental có thể rất nhỏ.

Ví dụ:

```text
database size: 130.5MB
database backup size: 8.3KB
repo1 backup size: 409B
```

Điều này không tự động có nghĩa backup lỗi.

---

## 11. Test restore

Backup thành công chưa đồng nghĩa với việc restore chắc chắn thành công.

Cần có restore test định kỳ trên môi trường test/standby riêng.

### Xem backup có thể dùng để restore

```bash
sudo -u postgres pgbackrest \
  --stanza=cluster_1 \
  info
```

### Restore latest

Ví dụ:

```bash
sudo -u postgres pgbackrest \
  --stanza=cluster_1 \
  restore \
  --type=latest
```

**Không chạy restore trực tiếp lên production data directory nếu chưa có kế hoạch và điều kiện an toàn.**

Nên test trên:

```text
Test VM
Test PostgreSQL instance
Test server
```

Sau restore:

1. Kiểm tra PostgreSQL start thành công.
2. Kiểm tra database.
3. Kiểm tra schema.
4. Kiểm tra một số bảng quan trọng.
5. Kiểm tra application connection.
6. Kiểm tra WAL/recovery state nếu sử dụng PITR.

---

## 12. Checklist vận hành

### Backup

- [ ] `pgbackrest check` thành công.
- [ ] Full backup tạo thành công.
- [ ] Incremental backup tạo thành công.
- [ ] Backup chain được reference đúng.
- [ ] Repository còn đủ dung lượng.
- [ ] WAL archive hoạt động.
- [ ] Cron hoạt động đúng lịch.

### Restore

- [ ] Có môi trường restore test.
- [ ] Restore Full thành công.
- [ ] Restore chain Incremental thành công.
- [ ] PostgreSQL start thành công sau restore.
- [ ] Kiểm tra được dữ liệu sau restore.
- [ ] Có quy trình PITR nếu yêu cầu RPO/RTO cần thiết.

### Retention

- [ ] Có cấu hình retention.
- [ ] Không xóa thủ công backup trong repository.
- [ ] Kiểm tra dung lượng repository định kỳ.

---

## 13. Các command thường dùng

### Check

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 check
```

### Info

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 info
```

### Info JSON

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 info --output=json
```

### Full backup

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 --type=full backup
```

### Differential backup

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 --type=diff backup
```

### Incremental backup

```bash
sudo -u postgres pgbackrest --stanza=cluster_1 --type=incr backup
```

### Xem version

```bash
pgbackrest version
```

---

## 14. Trạng thái setup hiện tại

Cấu hình hiện tại:

```text
Stanza:
    cluster_1

Backup:
    Full       : Thứ 7 02:00
    Incremental: Thứ 2–Thứ 6, mỗi 6 giờ
    Differential: Không sử dụng

Repository:
    repo1

Backup chain:
    Full → Incremental → Incremental → ...

Retention:
    Cần kiểm tra/cấu hình theo yêu cầu lưu trữ

Restore test:
    Cần thực hiện trên môi trường test
```

### Kết luận

Với output `pgbackrest info` hiện tại:

```text
stanza: cluster_1
status: ok
full backup: OK
incr backup: OK
backup reference total: 1 full
```

Phần backup cơ bản đã hoạt động.

Các bước còn lại cần hoàn thiện trước khi đưa vào vận hành chính thức:

```text
1. pgbackrest check
2. Verify cron
3. Verify WAL archive
4. Configure retention
5. Test restore
6. Định kỳ thực hiện restore test
```

# PostgreSQL: Kiến trúc & Nguyên lý hoạt động

## 1. Mục tiêu tài liệu

Tài liệu giải thích cách PostgreSQL hoạt động ở mức **kiến trúc và nguyên lý**, gắn với cấu hình cluster thực tế đang vận hành:

```text
Cluster    : cluster_1
PostgreSQL : 17
Patroni    : 3 node (core-1, core-2, core-3)
DCS        : etcd3
Backup     : pgBackRest (stanza: cluster_1)
Config     : config/node 1|node2|node3/patroni.yaml
```

Đối tượng đọc:

- Người mới bắt đầu muốn hiểu PostgreSQL từ nền tảng.
- DevOps/DBA cần tra cứu khi vận hành cluster.

Liên quan:

- Phân tích thiết kế: [postgres_design_analysis.md](postgres_design_analysis.md)
- Patroni/HA: [patroni_guide.md](patroni_guide.md)
- Backup: [pgbackrest_runbook.md](pgbackrest_runbook.md)

---

## 2. PostgreSQL là gì

PostgreSQL là hệ quản trị cơ sở dữ liệu quan hệ (RDBMS) mã nguồn mở, tuân thủ chuẩn SQL, có lịch sử từ Berkeley POSTGRES (1986) và đổi tên thành PostgreSQL vào 1996.

Đặc điểm chính:

```text
ACID            : Atomicity, Consistency, Isolation, Durability
MVCC            : Multi-Version Concurrency Control
Standards       : SQL standards compliance cao
Extensibility   : extension, custom type, custom operator, procedural language
Replication     : physical streaming + logical replication
Open source     : PostgreSQL License (permissive)
```

Vì sao cluster này dùng PostgreSQL 17:

```text
- Streaming replication ổn định, có replication slot
- pg_rewind: đồng bộ lại node cũ sau failover
- Parallel query cho analytics nhẹ
- Ecosystem backup mạnh (pgBackRest, pgBackRest chính là lựa chọn của cluster này)
```

---

## 3. Kiến trúc Process Model

PostgreSQL theo mô hình **process-per-connection** (mỗi kết nối = 1 process OS).

```text
                       ┌──────────────────────────────┐
                       │          postmaster          │
                       │   (process cha, PID 1 của    │
                       │    PostgreSQL instance)      │
                       └──────────────┬───────────────┘
                                      │ accept connection
                ┌─────────────────────┼─────────────────────┐
                │                     │                     │
        ┌───────▼───────┐     ┌───────▼───────┐     ┌───────▼───────┐
        │ backend #1    │     │ backend #2    │     │ backend #N    │
        │ (mỗi client   │     │               │     │               │
        │  1 process)   │     │               │     │               │
        └───────┬───────┘     └───────┬───────┘     └───────┬───────┘
                │                     │                     │
                └─────────────────────┼─────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │ background processes        │                             │
        │  ┌──────────────┐  ┌────────▼────────┐  ┌──────────────┐   │
        │  │ checkpointer │  │    walwriter    │  │   autovacuum │   │
        │  └──────────────┘  └─────────────────┘  └──────────────┘   │
        │  ┌──────────────┐  ┌─────────────────┐  ┌──────────────┐   │
        │  │  bgwriter     │  │  walsender/     │  │   archiver   │   │
        │  │              │  │  walreceiver    │  │ (archive)    │   │
        │  └──────────────┘  └─────────────────┘  └──────────────┘   │
        │  ┌──────────────┐  ┌─────────────────┐                     │
        │  │  stats       │  │  logical        │                     │
        │  │  collector   │  │  replication    │                     │
        │  └──────────────┘  └─────────────────┘                     │
        └────────────────────────────────────────────────────────────┘
```

### 3.1 postmaster

- Process cha, khởi động cùng service PostgreSQL.
- Lắng nghe port (`listen: 0.0.0.0:5432` trong config), nhận kết nối.
- Fork backend cho mỗi client mới.
- Quản lý shared memory, restart backend chết, phối hợp shutdown.

### 3.2 backend

- Mỗi client kết nối vào -> postmaster fork 1 backend process.
- Backend parse SQL, chạy planner/executor, ghi WAL, đọc/ghi buffer.
- `max_connections: 50` trong cluster này giới hạn tổng backend.

### 3.3 Các background process quan trọng

| Process | Vai trò |
|---|---|
| `checkpointer` | Ghi dirty page từ `shared_buffers` xuống disk عند checkpoint; ghi shutdown checkpoint |
| `walwriter` | Ghi WAL buffer xuống WAL file (đảm bảo durability) |
| `bgwriter` | Ghi dirty page định kỳ để executor không phải chờ I/O |
| `autovacuum` | Chạy VACUUM/ANALYZE tự động chống bloat |
| `walsender` | Ghi WAL stream gửi sang replica (streaming replication) |
| `walreceiver` | Nhận WAL stream từ primary (trên replica) |
| `archiver` | Chạy `archive_command` đẩy WAL ra repository |
| `stats collector` | Thu thập `pg_stat_*` |

Trong cluster này, `archiver` thực thi chính xác:

```bash
pgbackrest --stanza=cluster_1 archive-push %p
```

Xem chi tiết: [pgbackrest_runbook.md](pgbackrest_runbook.md).

---

## 4. Bộ nhớ: Memory Architecture

### 4.1 Các vùng bộ nhớ

```text
┌──────────────────────────────────────────────────────────┐
│                     PostgreSQL process                    │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │            shared_buffers (shared memory)          │  │
│  │      Cache page dữ liệu chính (buffer cache)      │  │
│  │         cluster này: 256MB                         │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │            WAL buffers                              │  │
│  │      Ghi WAL trước khi xuống disk                  │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │     work_mem (per operation, per connection)        │  │
│  │   Sort, Hash join... mỗi operation 1 phần          │  │
│  │         cluster này: 4MB                           │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                   OS Page Cache                          │
│       (PostgreSQL dùng read()/write() trực tiếp)         │
│         effective_cache_size: 1GB (gợi ý planner)       │
└──────────────────────────────────────────────────────────┘
```

### 4.2 Giải thích các tham số trong cluster hiện tại

```ini
shared_buffers: 256MB          # buffer cache chính
effective_cache_size: 1GB      # giả định planner: OS cache + shared_buffers
work_mem: 4MB                  # bộ nhớ cho sort/hash mỗi operation
maintenance_work_mem: 64MB     # bộ nhớ cho CREATE INDEX, VACUUM
max_connections: 50            # số backend tối đa
```

Nguyên tắc chung:

```text
shared_buffers        ≈ 25% RAM (cho dedicated DB server)
effective_cache_size  ≈ 50-75% RAM
work_mem              = RAM / max_connections / (số operation song song)
```

Cảnh báo `work_mem`:

```text
work_mem là per-operation, KHÔNG phải per-connection.

Một query có thể có nhiều sort/hash -> nhiều work_mem.
Nếu sort quá lớn, PostgreSQL ghi tạm xuống disk -> chậm nhưng không crash.
```

### 4.3 Đường đi của một query đọc dữ liệu

```text
1. Backend cần đọc page P
2. Tìm P trong shared_buffers?
   ├── Có  -> đọc từ RAM
   └── Không -> đọc từ OS page cache?
                 ├── Có  -> đọc từ RAM (OS cache)
                 └── Không -> đọc từ disk (I/O)
3. Đưa P vào shared_buffers (đánh dấu clean)
```

---

## 5. MVCC (Multi-Version Concurrency Control)

### 5.1 Nguyên tắc

PostgreSQL **không ghi đè** row cũ mà tạo **version mới** của row. Reader luôn thấy snapshot của thời điểm query bắt đầu, không bị block bởi writer.

```text
Transaction 100: UPDATE t SET x=1 WHERE id=1;
Transaction 101: SELECT x FROM t WHERE id=1;  -- vẫn thấy giá trị cũ (nếu bắt đầu trước commit)
```

### 5.2 Tuple header

Mỗi row (tuple) trong heap có header:

```text
┌─────────────────────────────────────────────┐
│ xmin  : transaction ID tạo ra tuple này    │
│ xmax  : transaction ID xóa/UPDATE tuple     │
│ cmin/cmax: command ID trong transaction     │
│ ctid  : vị trí tuple hiện tại (self/hàng)   │
│ xvac  : old style (rare)                    │
└─────────────────────────────────────────────┘
```

Visibility check (đọc 1 tuple):

```text
- xmin đã commit VÀ xmin <= snapshot  -> tuple này "tồn tại"
- xmax chưa commit HOẶC xmax > snapshot -> tuple chưa bị xóa
-> Cả 2 điều kiện đúng => tuple visible cho query này
```

### 5.3 Ví dụ minh họa

```text
Ban đầu:  (id=1, name='A')   xmin=100 xmax=0

Transaction 200: UPDATE
  -> Tạo tuple MỚI: (id=1, name='B')  xmin=200 xmax=0
  -> Đánh dấu tuple CŨ:   (id=1, name='A')  xmin=100 xmax=200

Reader snapshot=190: thấy 'A' (tuple mới chưa commit/xcòn sau snapshot)
Reader snapshot=250: thấy 'B' (tuple cũ xmax=200 đã commit)
```

### 5.4 Hệ quả của MVCC

```text
Ưu điểm:
  + Không block reader khi writer ghi
  + Dễ implement isolation level cao (Repeatable Read, Serializable)
  + Backup/replication consistent snapshot

Nhược điểm:
  + Bloat: tuple chết tích lũy -> cần VACUUM
  + UPDATE = ghi row mới (không in-place) -> nặng hơn InnoDB về ghi
  + Index không versioned -> cần HOT chain / bloat index
```

---

## 6. WAL & Crash Recovery

### 6.1 WAL là gì

Write-Ahead Logging: mọi thay đổi ghi xuống **WAL trước**, rồi mới ghi data page.

```text
1. Thay đổi page P trong shared_buffers
2. Ghi WAL record mô tả thay đổi vào WAL buffer
3. WAL buffer -> WAL file (walwriter)  [đây là điểm durability]
4. Sau đó page P mới được ghi xuống data file (checkpointer/bgwriter)
```

Nguyên tắc: **"WAL trước, data sau"** -> crash lúc giữa chừng thì replay WAL để khôi phục.

### 6.2 Cấu hình WAL trong cluster

```ini
wal_level: replica                # ghi đủ info cho replica + PITR
wal_keep_size: 256MB              # giữ WAL cũ cho replica không cần slot
max_wal_senders: 4                # số walsender đồng thời
max_replication_slots: 4          # số replication slot
max_wal_size: 512MB               # giới hạn WAL trước checkpoint
archive_mode: on                  # bật archive WAL ra ngoài
archive_timeout: 600s             # force checkpoint mỗi 10p nếu không có traffic
archive_command: pgbackrest --stanza=cluster_1 archive-push %p
```

### 6.3 Checkpoint

Checkpoint ghi toàn bộ dirty page xuống disk -> đánh dấu điểm recovery tối thiểu.

```text
Crash xảy ra:
  recovery bắt đầu từ checkpoint gần nhất
  replay WAL từ checkpoint -> hiện trạng mới nhất
```

### 6.4 Crash recovery & PITR

```text
Crash recovery (mặc định):
  PostgreSQL tự replay WAL khi start

PITR (Point-In-Time Recovery):
  restore_command lấy WAL từ archive
  restore_command = pgbackrest --stanza=cluster_1 archive-get %f "%p"
  -> khôi phục về thời điểm mong muốn
```

Xem cách chạy: [pgbackrest_runbook.md](pgbackrest_runbook.md).

---

## 7. Transaction & Locking

### 7.1 ACID trong PostgreSQL

```text
Atomicity   : WAL + transaction log -> rollback bằng undo log ảo (xid mark)
Consistency : constraint (PK, FK, CHECK, UNIQUE)
Isolation   : MVCC + lock manager
Durability  : WAL flush theo synchronous_commit
```

### 7.2 Isolation level

| Level | Dirty read | Non-repeatable read | Phantom |
|---|---|---|---|
| Read Committed (mặc định) | Không | Có | Có |
| Repeatable Read | Không | Không | Có* |
| Serializable | Không | Không | Không |

```text
* PostgreSQL RR dùng snapshot -> phantom cũng không thấy (khác chuẩn SQL gốc)
```

Đổi isolation:

```sql
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
```

### 7.3 Lock

```text
Table lock    : ACCESS SHARE, ROW SHARE, ROW EXCLUSIVE, SHARE, ...
Row lock      : FOR UPDATE, FOR SHARE
Deadlock      : PostgreSQL tự detect và kill 1 transaction
```

Xem lock hiện tại:

```sql
SELECT pid, state, wait_event_type, wait_event, query
FROM pg_stat_activity
WHERE state <> 'idle';
```

### 7.4 synchronous_commit

```ini
synchronous_commit: on   # cluster này
```

```text
on            : commit phải được flush xuống WAL file -> an toàn, mặc định
remote_write  : commit flush trên primary + ghi xuống OS trên sync replica
remote_apply  : commit đã apply trên sync replica
off           : KHÔNG flush -> nhanh hơn nhưng có thể mất commit nếu crash
```

Trong cluster HA với Patroni, `synchronous_commit: on` kết hợp `synchronous_mode` của Patroni để đảm bảo commit đã nằm trên >= 1 sync standby.

---

## 8. VACUUM & Bloat

### 8.1 Vì sao cần VACUUM

Do MVCC, tuple chết (đã bị UPDATE/DELETE) không tự biến mất:

```text
DELETE FROM t WHERE ...;
  -> Dữ liệu vẫn nằm trên disk, chỉ đánh dấu xmax
  -> Cần VACUUM để thu hồi không gian
```

### 8.2 Các loại VACUUM

```text
VACUUM (thường)      : thu hồi tuple chết, giữ snapshot, KHÔNG trả hết disk
VACUUM FULL          : viết lại toàn bảng -> chặn ghi, trả disk thật
VACUUM (analyze)     : cập nhật thống kê cho planner
autovacuum           : chạy tự động (cluster này: mặc định on)
```

### 8.3 Anti-wraparound

```text
Transaction ID (xid) là 32-bit, wraparound sau ~4 tỷ transaction.
VACUUM "freeze" tuple cũ để tránh wraparound.
Nếu không freeze kịp -> PostgreSQL từ chối ghi (để tránh mất dữ liệu).
```

Kiểm tra:

```sql
SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database
ORDER BY xid_age DESC;
```

Cảnh báo khi `xid_age` > 1 tỷ.

---

## 9. Query Processing (tổng quan)

```text
SQL text
   │
   ▼
┌─────────┐
│ Parser  │  -> parse tree (syntax check)
└────┬────┘
     ▼
┌──────────┐
│ Rewriter │  -> áp view, rule
└────┬─────┘
     ▼
┌──────────┐
│ Planner  │  -> chọn plan dựa trên cost (statistics từ ANALYZE)
│(Optimizer)│
└────┬─────┘
     ▼
┌──────────┐
│ Executor │  -> chạy plan (iterator/Volcano model)
└──────────┘
```

Xem plan:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM t WHERE id = 1;
```

Xem thống kê planner dùng:

```sql
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum
FROM pg_stat_user_tables;
```

---

## 10. Physical Replication trong cluster hiện tại

### 10.1 Streaming replication

```text
Primary (walsender) ──WAL stream──> Replica (walreceiver)
```

Trong cluster này:

```ini
max_wal_senders: 4          # cho phép tối đa 4 luồng gửi
max_replication_slots: 4    # 4 slot (1 primary + 3 node -> slot cho từng replica)
wal_level: replica          # WAL đủ info cho replica
hot_standby: 'on'           # replica cho phép đọc
use_slots: true             # Patroni dùng replication slot (không mất WAL)
```

### 10.2 Replication slot

```text
Replication slot giữ WAL lại cho tới khi replica consume xong.
Ưu điểm  : replica không bị "vỡ" khi primary tạo WAL quá nhanh
Nhược điểm: nếu replica chết lâu, slot tích lũy WAL -> đầy disk
```

Kiểm tra slot:

```sql
SELECT slot_name, active, restart_lsn, wal_status
FROM pg_replication_slots;
```

### 10.3 pg_hba cho replication

```ini
host replication replicator 127.0.0.1/32 trust
host replication replicator 192.168.1.0/24 scram-sha-256
```

```text
- local   : peer auth
- 127.0.0.1 replication: trust (cho script local)
- subnet cluster: scram-sha-256 (mạnh, nên dùng)
```

### 10.4 Quan sát replication

```sql
-- Trên primary
SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;

-- Trên replica
SELECT pg_is_in_recovery();
SELECT pg_last_wal_replay_lsn();
SELECT now() - pg_last_xact_replay_timestamp() AS replication_delay;
```

---

## 11. Kết nối & Authentication

### 11.1 pg_hba.conf (trong cluster này)

```text
local   all             all                     peer
host    all             all    0.0.0.0/0        scram-sha-256
host    replication     replicator 127.0.0.1/32 trust
host    replication     replicator 192.168.1.0/24 scram-sha-256
```

```text
peer            : xác thực theo OS user (chỉ local socket)
scram-sha-256   : mật khẩu mạnh (nên dùng cho network)
trust           : KHÔNG xác thực (chỉ an toàn khi giới hạn IP chặt)
```

### 11.2 Kết nối

```bash
psql -h 127.0.0.1 -p 5432 -U postgres -d postgres
```

Kiểm tra kết nối qua Patroni REST API:

```bash
curl -s http://192.168.1.155:8008/primary
curl -s http://192.168.1.155:8008/patroni
```

---

## 12. Cấu trúc thư mục data directory

```text
/var/lib/postgresql/17/main/
├── base/            # data file của các database
├── global/          # shared catalog (pg_database, pg_authid...)
├── pg_wal/          # WAL file (16MB/mỗi file mặc định)
├── pg_multixact/    # lock metadata
├── pg_stat/         # stats
├── pg_tblspc/       # symlink tablespace
├── pg_xact/         # commit log (clog)
├── postgresql.conf  # cấu hình chính
├── pg_hba.conf      # authentication
└── postgresql.auto.conf  # ALTER SYSTEM SET ...
```

Kiểm tra:

```sql
SHOW data_directory;
SHOW config_file;
```

---

## 13. Quan sát & Monitoring

### 13.1 View quan trọng

```sql
-- Kết nối đang hoạt động
SELECT pid, usename, datname, state, query_start, left(query, 80)
FROM pg_stat_activity;

-- Tuple bị lock
SELECT * FROM pg_locks WHERE NOT granted;

-- Chậm query
SELECT pid, now() - query_start AS duration, state, left(query, 100)
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY duration DESC;

-- WAL archiver (quan trọng cho backup)
SELECT * FROM pg_stat_archiver;
```

### 13.2 Script sẵn có trong repo

```bash
# Trạng thái cluster qua Patroni
patronictl -c /etc/patroni/patronictl.yml list

# Kiểm tra etcd
etcdctl --endpoints=http://172.24.13.131:2379 member list

# Kiểm tra archive
cat common_command/psql/check_archive.sql
cat common_command/psql/archive_status_check.sql
```

### 13.3 Logging

```ini
logging_collector: 'on'
timezone: 'Asia/Ho_Chi_Minh'
```

```bash
tail -f /var/log/postgresql/postgresql-17-main.log
```

---

## 14. Checklist "kiểm tra 1 instance PostgreSQL"

```text
[ ] Instance đang chạy
      systemctl status postgresql@17-main

[ ] Vai trò node (primary/replica)
      psql -c "SELECT pg_is_in_recovery();"

[ ] Kết nối
      psql -c "SELECT version();"

[ ] Replication (nếu là primary)
      psql -c "SELECT * FROM pg_stat_replication;"

[ ] Replication lag (nếu là replica)
      psql -c "SELECT now() - pg_last_xact_replay_timestamp();"

[ ] WAL archiver
      psql -c "SELECT * FROM pg_stat_archiver;"

[ ] Bloat/autovacuum
      psql -c "SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;"

[ ] Lock chờ
      psql -c "SELECT pid, wait_event, query FROM pg_stat_activity WHERE wait_event_type = 'Lock';"

[ ] Patroni status
      patronictl -c /etc/patroni/patronictl.yml list

[ ] Backup status
      sudo -u postgres pgbackrest --stanza=cluster_1 info
```

---

## 15. Tổng kết

```text
PostgreSQL = process model + MVCC + WAL + cost-based planner

- Process model     : mỗi client 1 backend, background processes chuyên trách
- Bộ nhớ            : shared_buffers + OS cache + work_mem
- MVCC              : không block reader, đổi lại là bloat -> VACUUM
- WAL               : ghi trước dữ liệu sau -> crash recovery + PITR + replication
- Replication       : streaming WAL + replication slot
- cluster này       : PG17 + Patroni 3 node + etcd + pgBackRest
```

Tài liệu tiếp theo:

- [postgres_design_analysis.md](postgres_design_analysis.md) — phân tích thiết kế
- [patroni_guide.md](patroni_guide.md) — vận hành HA

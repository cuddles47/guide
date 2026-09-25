# Patroni: Kiến trúc & Vận hành Cluster PostgreSQL HA

## 1. Mục tiêu tài liệu

Giải thích **Patroni** — công cụ quản lý high availability cho PostgreSQL — và cách nó vận hành cluster thực tế trong repo này.

```text
Cluster scope : clusterdevops_ducnm2
Namespace     : percona_lab_ducnm2
PostgreSQL    : 17
Nodes         : core-1 (192.168.1.155), core-2 (.156), core-3 (.157)
DCS           : etcd3 (192.168.1.155/156/157:2379)
Config        : config/node 1/patroni.yaml, config/node2/patroni.yaml, config/node3/patroni.yaml
Backup        : pgBackRest stanza cluster_1
```

Tiền đề: [postgres_fundamentals.md](postgres_fundamentals.md), [postgres_design_analysis.md](postgres_design_analysis.md).

---

## 2. PostgreSQL không có HA mặc định

### 2.1 Vấn đề

```text
PostgreSQL "mặc định":
  - 1 primary ghi
  - streaming replication (standby chỉ đọc)
  - KHÔNG tự failover khi primary chết
  - KHÔNG tự quyết định ai là primary mới
  - KHÔNG tự bỏ primary cũ khi quay lại (split-brain)
```

### 2.2 Những gì phải tự làm khi không có Patroni

```text
1. Phát hiện primary chết
2. Chọn 1 standby để promote
3. Đổi kết nối application (DNS/VIP/proxy)
4. Cập nhật replica còn lại trỏ sang primary mới
5. Xử lý primary cũ khi hồi phục (pg_rewind / rebuild)
6. Đồng bộ cấu hình trên tất cả nodes
7. Tránh split-brain (2 node cùng nhận ghi)
```

Patroni tự động hóa toàn bộ list trên.

### 2.3 Patroni là gì

```text
Patroni = "tư vấn" (agent) chạy trên MỖI node PostgreSQL:
  - Quan sát state của node mình (primary hay replica, lag bao nhiêu)
  - Ghi/đọc state chung vào DCS (etcd/consul/zookeeper)
  - Ra quyết định: ai là leader, khi nào failover, cấu hình nào áp dụng
  - Khởi động/dừng/reload PostgreSQL, tạo replica, pg_rewind
```

```text
Lưu ý quan trọng:
  Patroni KHÔNG phải HA proxy.
  Application vẫn phải trỏ vào primary qua VIP/DNS/proxy
  hoặc đọc state từ Patroni REST API.
```

So sánh nhanh:

```text
repgar     : chỉ quản lý replication + failover, ít tính năng cấu hình động
Stolon     : consul-based, ít active hơn
Patroni    : phổ biến nhất, nhiều DCS, cấu hình động qua DCS, production-proven
```

---

## 3. Kiến trúc tổng thể

### 3.1 Sơ đồ 3 node

```text
                 ┌─────────────────────────────────────────┐
                 │                  etcd3                  │
                 │   (Distributed State Store = DCS)       │
                 │  /scope/clusterdevops_ducnm2/...        │
                 │   - leader key (TTL 30s)                │
                 │   - state (primary/replica, sync, xlog) │
                 │   - config (Patroni dynamic config)     │
                 └──────▲──────────────▲──────────────▲────┘
                        │              │              │
              ┌─────────┴───┐   ┌──────┴──────┐  ┌────┴─────────┐
              │   core-1    │   │   core-2    │  │   core-3     │
              │ .155        │   │ .156        │  │ .157         │
              │ ┌─────────┐ │   │ ┌─────────┐ │  │ ┌─────────┐  │
              │ │ Patroni │ │   │ │ Patroni │ │  │ │ Patroni │  │
              │ │ agent   │ │   │ │ agent   │ │  │ │ agent   │  │
              │ └────┬────┘ │   │ └────┬────┘ │  │ └────┬────┘  │
              │ ┌────▼────┐ │   │ ┌────▼────┐ │  │ ┌────▼────┐  │
              │ │PostgreSQL│ │   │ │PostgreSQL│ │  │ │PostgreSQL│ │
              │ │ 5432    │ │   │ │ 5432    │ │  │ │ 5432    │  │
              │ └────┬────┘ │   │ └────┬────┘ │  │ └────┬────┘  │
              │ ┌────▼────┐ │   │ ┌────▼────┐ │  │ ┌────▼────┐  │
              │ │REST API │ │   │ │REST API │ │  │ │REST API │  │
              │ │  8008   │ │   │ │  8008   │ │  │ │  8008   │  │
              │ └─────────┘ │   │ └─────────┘ │  │ └─────────┘  │
              └─────────────┘   └─────────────┘  └──────────────┘
```

### 3.2 Vai trò từng thành phần

| Thành phần | Vai trò |
|---|---|
| Patroni agent | Process điều phối trên mỗi node; một (và chỉ một) node giữ lease leader |
| etcd3 (DCS) | Lưu state chung: leader key có TTL, trạng thái node, config động |
| PostgreSQL | Engine dữ liệu thật; Patroni chỉ là "quản gia" khởi động/sửa config |
| REST API (8008) | Endpoint để `patronictl`, monitoring, health check hỏi state |
| pgBackRest | Archive/restore WAL & backup (xem [pgbackrest_runbook.md](pgbackrest_runbook.md)) |

### 3.3 Nguyên tắc hoạt động cốt lõi

```text
1. Leader election bằng TTL lease trong etcd
   - Patroni leader renew key mỗi loop_wait (10s)
   - Key hết hạn sau ttl (30s) nếu không renew được
   - Patroni khác thấy key hết hạn -> ứng viên promote chính nó

2. Mọi state quan trọng nằm trong etcd (không nằm trong PG)
   - ai là leader
   - node nào sync, lag bao nhiêu
   - config động (Patroni + PostgreSQL parameters)

3. PostgreSQL vẫn "bình thường"
   - Patroni quản lý qua pg_ctl / pg_rewind / SQL
   - Không agent đặc biệt trong PG
```

---

## 4. Phân tích cấu hình `patroni.yaml`

### 4.1 Identity & scope

```yaml
namespace: percona_lab_ducnm2
scope: clusterdevops_ducnm2
name: core-1          # core-2, core-3 tương ứng từng node
```

```text
scope    : tên cluster trong DCS -> key etcd: /scope/clusterdevops_ducnm2/...
namespace: phân biệt môi trường/tên lửa (dev, lab...) cùng scope
name     : tên node DUY NHẤT trong scope (không được trùng)
         -> trùng name = 2 agent tranh nhau 1 lease -> lỗi nghiêm trọng
```

### 4.2 REST API

```yaml
restapi:
    listen: 0.0.0.0:8008
    connect_address: 192.168.1.155:8008   # .156, .157 tương ứng
```

```text
- listen        : cổng nghe (0.0.0.0 -> chấp nhận từ ngoài)
- connect_address: địa chỉ công bố cho node khác / patronictl

An ninh: API này KHÔNG có auth mặc định.
         -> chỉ mở firewall cho subnet quản trị, không public ra Internet.
```

Kiểm tra:

```bash
curl -s http://192.168.1.155:8008/patroni | python3 -m json.tool
curl -s http://192.168.1.155:8008/primary
curl -s http://192.168.1.155:8008/replica
```

### 4.3 DCS — etcd3

```yaml
etcd3:
  hosts: [192.168.1.155:2379, 192.168.1.156:2379, 192.168.1.157:2379]
```

```text
- 3 nút etcd = tolerates 1 node chết (quorum 2/3)
- Nếu chết 2 node etcd -> MẤT QUORUM -> không failover được nữa
- Nên chạy etcd cùng node với PG (như hiện tại) hoặc node riêng
```

Kiểm tra etcd:

```bash
etcdctl --endpoints=http://192.168.1.155:2379,http://192.168.1.156:2379,http://192.168.1.157:2379 member list
etcdctl --endpoints=... endpoint health
etcdctl --endpoints=... get /scope/clusterdevops_ducnm2 --prefix --keys-only
```

```text
Lưu ý: common_command/quick_check.sh đang dùng endpoint 172.24.13.131:2379
(một dải IP khác, có thể là config cũ). Khi chạy thủ công nên dùng dải
192.168.1.15x khớp patroni.yaml.
```

### 4.4 `bootstrap.dcs` — tham số failover

```yaml
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
```

| Tham số | Giá trị | Ý nghĩa |
|---|---|---|
| `ttl` | 30s | Thời gian leader key sống nếu không renew. Hết ttl -> coi như leader chết |
| `loop_wait` | 10s | Patroni ngủ bao lâu giữa 2 lần check/renew |
| `retry_timeout` | 10s | Timeout cho 1 thao tác DCS/DB; quá -> node từ bỏ thao tác |
| `maximum_lag_on_failover` | 1MB (1048576) | Replica lag > 1MB thì KHÔNG được chọn làm primary mới |

```text
Quan hệ: ttl > loop_wait + retry_timeout
  30 > 10 + 10  -> đúng, còn dư 10s

Nếu sai (ví dụ ttl=10, loop_wait=10) -> leader renew không kịp
  -> failover "giả" xảy ra khi hệ thống vẫn khỏe (split-brain nguy hiểm)
```

Thời gian failover tối thiểu (ước tính):

```text
TTL hết hạn + Patroni khác detect + promote
≈ ttl (30s) + vài giây xử lý
→ RTO failover thực tế thường 30-45s (chưa tính app reconnect)
Muốn nhanh hơn: hạ ttl (ví dụ 20) -> đánh đổi: dễ failover giả khi network chập chờn
```

### 4.5 Synchronous replication

```yaml
    synchronous_mode: true
    synchronous_mode_strict: true
    synchronous_node_count: 1
```

```yaml
postgresql:
  parameters:
    synchronous_commit: on
```

```text
synchronous_mode: true
  -> Patroni tự quản lý synchronous_standby_names
  -> Commit chỉ thành công khi primary + 1 sync standby đã nhận

synchronous_mode_strict: true
  -> KHÔNG có sync standby -> Patroni từ chối nhận ghi (write bị block)
     (nếu false: hệ thống tự hạ xuống asynchronous -> RPO > 0 nhưng không downtime)

synchronous_node_count: 1
  -> cần đúng 1 sync standby (>=1)
  -> nếu node sync chết, node replica khác phải lên làm sync trước khi ghi tiếp
```

```text
Đánh đổi:
  + RPO = 0 cho ghi đã ack (không mất data khi failover)
  - synchronous_mode_strict=true: MẤT WRITE nếu không đủ sync standby
  -> Phù hợp data quan trọng, phải kèm monitoring alert khi sync standby < 1
```

Tag `nosync`:

```yaml
tags:
  nosync: false     # core-1, core-3
  nosync: true      # core-2
```

```text
nosync: true  -> node này KHÔNG bao giờ được chọn làm sync standby
core-2 được đặt nosync:true -> hệ thống sync standby = core-1 hoặc core-3

Ý nghĩa có thể: core-2 yếu hơn / cần đọc nhiều / chuẩn bị thay thế...
-> Nếu MỌI node khác chết, synchronous_mode_strict=true sẽ block ghi.
   Cân nhắc lại cấu hình này khi vận hành.
```

### 4.6 Replication & PostgreSQL parameters

```yaml
      postgresql:
        use_pg_rewind: true
        use_slots: true
        parameters:
          wal_level: replica
          hot_standby: 'on'
          wal_keep_size: 256MB
          max_wal_senders: 4
          max_replication_slots: 4
          wal_log_hints: 'on'
          max_wal_size: 512MB
          archive_mode: on
          archive_timeout: 600s
          archive_command: 'pgbackrest --stanza=cluster_1 archive-push %p'
```

| Tham số | Ý nghĩa trong Patroni |
|---|---|
| `use_pg_rewind: true` | Node cũ rejoin sau failover bằng pg_rewind thay vì rebuild |
| `use_slots: true` | Tự tạo replication slot cho mỗi replica -> không mất WAL |
| `max_wal_senders: 4` | Đủ cho 3 replica + 1 dư |
| `max_replication_slots: 4` | Slot cho 3 replica + 1 dư |
| `wal_log_hints: 'on'` | Điều kiện cho pg_rewind |
| `archive_timeout: 600s` | Archive WAL đều kể cả khi hệ thống idle |

```text
Lưu ý: Patroni chỉ áp bootstrap.dcs.parameters khi TẠO cluster (bootstrap).
Sau đó, thay đổi cấu hình nên qua `patronictl edit-config` (dynamic config)
để áp đồng bộ trên mọi node.
```

### 4.7 Authentication & pg_hba

```yaml
postgresql:
  data_dir: /var/lib/postgresql/17/main
  config_dir: /etc/postgresql/17/main
  bin_dir: /usr/lib/postgresql/17/bin
  pgpass: /opt/secretpg/pgpass
  authentication:
    replication:
      username: replicator
      password: ...
    superuser:
      username: postgres
      password: ...
```

```yaml
      pg_hba:
        - local   all             all                      peer
        - host    replication     replicator 127.0.0.1/32  trust
        - host    replication     replicator 192.168.1.0/24 scram-sha-256
        - host    all             all      0.0.0.0/0        scram-sha-256
```

```text
Patroni tự ghi pg_hba từ cấu hình này khi bootstrap.
Replication authentication được dùng cho streaming giữa các node.
```

### 4.8 Bootstrap & tạo replica

```yaml
bootstrap:
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  create_replica_methods:
    - basebackup
  basebackup:
    checkpoint: 'fast'
```

```text
data-checksums : kiểm tra integrity page (nên bật từ đầu; bật sau phải dump/load lại)
basebackup      : pg_basebackup từ primary -> tạo replica mới
checkpoint=fast : replica mới quét WAL ít hơn, nhanh hơn

Có thể thêm pgbackrest làm replica method (restore từ repo thay vì stream)
để bootstrap node mới nhanh với DB lớn — tùy môi trường.
```

### 4.9 `bootstrap.dcs` vs `postgresql.parameters`

```text
bootstrap.dcs.*          : KHÔNG bao giờ đổi sau khi bootstrap
  - ttl, loop_wait, retry_timeout
  - synchronous_mode*
  - use_pg_rewind, use_slots
  - parameters (các PG parameter lúc init)

postgresql.* (ngoài bootstrap) : thông tin node này (data_dir, listen, auth)
  -> đổi tên node/sửa auth thì sửa file rồi reload
```

---

## 5. Vòng đời: Leader, Failover, Switchover

### 5.1 Trạng thái bình thường

```text
1. Node đầu tiên khởi động -> chưa có leader key trong etcd
   -> bootstrap: initdb, start PG, ghi leader key (nếu được chỉ định)

2. Node khác khởi động -> thấy đã có leader
   -> pg_basebackup từ leader, start PG ở chế độ replica
   -> ghi state replica vào DCS

3. Leader renew TTL mỗi loop_wait (10s)
```

### 5.2 Failover (primary chết đột ngột)

```text
Thời điểm t=0   : primary crash / network partition
t=0..30s        : leader key vẫn còn trong etcd (TTL chưa hết)
                  Patroni khác vẫn tin primary còn (chưa failover)
t=30s           : TTL hết hạn -> key biến mất
t≈30-35s        : Patroni trên node khác thấy key mất
                  -> kiểm tra: candidate có lag <= maximum_lag_on_failover (1MB)
                  -> candidate promote: pg_ctl promote + đặt leader key mới
t≈35s+          : replica còn lại rebase sang primary mới
                  (dùng pg_rewind / recreate slot theo cấu hình)
t≈35-45s        : primary cũ hồi phục (nếu có) -> Patroni dừng PG cũ
                  -> pg_rewind về bản chính -> rejoins làm replica
```

```text
RPO: 0 ghi đã commit nhờ synchronous_mode=1 sync standby
RTO: ~30-45s (chủ yếu do TTL=30)
```

### 5.3 Switchover (chuyển chủ có kiểm soát)

```text
Dùng khi: maintenance planned, đổi primary chủ động
Khác failover:
  + Patroni chủ động: demote leader cũ TRƯỚC, rồi promote node mới
  + Không mất ghi, không cần chờ TTL hết
  + Lệnh có --force / --scheduled
```

```bash
patronictl -c /etc/patroni/patronictl.yml switchover clusterdevops_ducnm2
patronictl -c /etc/patroni/patronictl.yml switchover clusterdevops_ducnm2 --candidate core-2
```

### 5.4 Vì sao vẫn cần VIP/proxy

```text
Patroni không đổi IP.
Application đang kết nối 192.168.1.155:5432 mà node đó chết -> gãy kết nối.

Các cách:
1. VIP floating (keepalived) trên primary -> VIP dời theo node
2. HAProxy/ProxySQL đọc /primary từ Patroni API -> đổi backend động
3. DNS round-robin + retry khi đổi (chậm hơn)
```

---

## 6. Runbook vận hành

### 6.1 Kiểm tra trạng thái

```bash
# Trạng thái cluster (lệnh chính)
patronictl -c /etc/patroni/patronictl.yml list

# Output mẫu (minh họa, format khác nhau theo version Patroni):
# +----+----------+---------+------+---------+--------------+------+
# | # | Member   | Host    | Port |  State  |   TL | Lag in MB | Tags |
# +----+----------+---------+------+---------+------+-----------+------+
# | 1  | core-1   | 192.168.1.155 | 5432 | Leader      |    3 |         0 |      |
# | 2  | core-3   | 192.168.1.157 | 5432 | SyncStandby |    3 |         0 |      |
# | 3  | core-2   | 192.168.1.156 | 5432 | Replica     |    3 |         0 | nosync|
# +----+----------+---------+------+---------+------+-----------+------+
#
# Đọc:
#   State = Leader       -> node đang là primary
#   State = SyncStandby  -> standby đồng bộ (commit phải có trên đây)
#   State = Replica      -> standby thường (không đồng bộ)
#   Tags  = nosync       -> core-2 không bao giờ làm sync standby
#   Lag in MB            -> độ trễ replay so với primary

patronictl -c /etc/patroni/patronictl.yml list --extended
patronictl -c /etc/patroni/patronictl.yml list --verbose
```

```bash
# REST API
curl -s http://192.168.1.155:8008/patroni | python3 -m json.tool
curl -s http://192.168.1.155:8008/primary ; echo
curl -s http://192.168.1.155:8008/replica ; echo

# Trạng thái PostgreSQL từng node
psql -h 192.168.1.155 -U postgres -c "SELECT pg_is_in_recovery();"
psql -h 192.168.1.155 -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### 6.2 Log

```bash
# Patroni log (tuỳ install)
journalctl -u patroni -f
tail -f /var/log/patroni/patroni.log

# PostgreSQL log
tail -f /var/log/postgresql/postgresql-17-main.log
```

### 6.3 Reload cấu hình

```bash
# Reload cấu hình PostgreSQL (PG parameters)
patronictl -c /etc/patroni/patronictl.yml reload clusterdevops_ducnm2

# Reload file patroni.yaml (identity/auth)
patronictl -c /etc/patroni/patronictl.yml reload /etc/patroni/patroni.yaml
```

### 6.4 Đổi cấu hình động (khuyên dùng)

```bash
# Sửa cấu hình trong DCS -> áp trên TẤT CẢ node
patronictl -c /etc/patroni/patronictl.yml edit-config
```

```text
Dùng edit-config để đổi:
  - PostgreSQL parameters (work_mem, maintenance_work_mem, ...)
  - synchronous_mode, synchronous_node_count
  - ttl, loop_wait, retry_timeout

Patroni sẽ:
  1. Ghi YAML mới vào etcd
  2. Reload/restart từng node theo mong đợi (some require restart)
```

```bash
# Xem config động hiện tại
patronictl -c /etc/patroni/patronictl.yml get-config
```

### 6.5 Failover / Switchover thủ công

```bash
# Switchover (an toàn, planned)
patronictl -c /etc/patroni/patronictl.yml switchover clusterdevops_ducnm2

# Failover (khi primary đã chết thật)
patronictl -c /etc/patroni/patronictl.yml failover clusterdevops_ducnm2

# Chọn candidate cụ thể
patronictl -c /etc/patroni/patronictl.yml failover clusterdevops_ducnm2 --candidate core-3
```

```text
Cảnh báo:
  Chỉ chạy failover khi XÁC ĐỊNH primary đã chết thật.
  Chạy nhầm khi primary còn sống -> có 2 primary (split-brain).
```

### 6.6 Dừng/tạm dừng (maintenance)

```bash
# Tạm dừng failover (khi maintenance DCS/cluster)
patronictl -c /etc/patroni/patronictl.yml pause clusterdevops_ducnm2

# Bật lại
patronictl -c /etc/patroni/patronictl.yml resume clusterdevops_ducnm2
```

### 6.7 Thêm / gỡ node

```text
Thêm node:
  1. Cài PostgreSQL 17 + Patroni
  2. Copy patroni.yaml -> sửa name (core-4), connect_address, restapi
  3. Khởi động patroni -> tự pg_basebackup từ leader
  4. patronictl list kiểm tra

Gỡ node:
  1. patronictl edit-config -> thêm tag nofailover/nosync nếu chỉ tạm
  2. Dừng patroni trên node
  3. Xóa replication slot trên primary nếu không dùng nữa:
       SELECT pg_drop_replication_slot('slot_name');
```

### 6.8 Restore node hỏng

```text
Node không join lại được (data hỏng / WAL sai / slot hỏng):

1. Dừng Patroni trên node đó
2. Xóa data_dir (CẪN TRỌN, sau khi backup nếu cần)
3. Khởi động lại Patroni
   -> tự pg_basebackup từ primary mới
4. patronictl list xác nhận state

Hoặc restore từ pgBackRest rồi start Patroni:
   sudo -u postgres pgbackrest --stanza=cluster_1 restore --delta --type=latest
   (xem [pgbackrest_runbook.md](pgbackrest_runbook.md))
```

---

## 7. Monitoring & Alerting

### 7.1 Metric cần theo dõi

```text
1. Leader có tồn tại không
      patronictl list / etcd key / REST API /primary trả 200

2. Số node healthy
      3/3 node Up trong patronictl list

3. Replication lag
      pg_stat_replication.replay_lag
      patronictl list cột "Lag in MB"

4. Sync standby có >= 1 không        (với synchronous_mode_strict=true)
      -> THIẾU = WRITE SẮP BỊ BLOCK  (alert mức cao)

5. WAL archiver
      pg_stat_archiver.failed_count tăng bất thường

6. Replication slot
      pg_replication_slots: active=false, pg_wal_lsn_diff lớn -> slot giữ WAL

7. Disk (data + WAL + repo pgBackRest)

8. Xid age (wraparound)
      age(datfrozenxid) > 1e9

9. DCS: etcd quorum (3/3 member healthy)

10. Failover events (Patroni log / event stream)
```

### 7.2 Script kiểm tra nhanh

```bash
# Quick check (có sẵn trong repo)
cat common_command/quick_check.sh
#   patronictl -c /etc/patroni/patronictl.yml list
#   etcdctl --endpoints=... member list

# Kiểm tra archiver (SQL có sẵn)
cat common_command/psql/check_archive.sql
cat common_command/psql/archive_status_check.sql
```

### 7.3 Query kiểm tra tổng hợp

```sql
-- Role node
SELECT pg_is_in_recovery() AS is_replica,
       CASE WHEN pg_is_in_recovery()
            THEN pg_last_wal_replay_lsn()
            ELSE pg_current_wal_lsn() END AS current_lsn;

-- Lag replication (trên primary)
SELECT client_addr, state, sync_state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;

-- Archiver
SELECT archived_count, failed_count,
       last_archived_wal, last_archived_time,
       last_failed_wal, last_failed_time
FROM pg_stat_archiver;

-- Slot
SELECT slot_name, active, wal_status,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS slot_lag_bytes
FROM pg_replication_slots;
```

---

## 8. Sự cố thường gặp

### 8.1 Cluster không có Leader

```text
Triệu chứng:
  patronictl list -> không có cột Leader / "No leader"

Nguyên nhân có thể:
  1. etcd mất quorum (2/3 node chết)
  2. Tất cả Patroni đang pause
  3. Network partition: không node nào renew được key
  4. TTL hết trước khi renew (loop_wait/retry_timeout sai)

Xử lý:
  1. Kiểm tra etcd: etcdctl endpoint health / member list
  2. Khởi động lại etcd node chết
  3. Kiểm tra log Patroni từng node
  4. Nếu cần: patronictl resume; hoặc khởi động lại 1 Patroni
  5. KHÔNG promote tay trừ khi chắc chắn
```

### 8.2 Write bị block (synchronous_mode_strict)

```text
Triệu chứng:
  Ứng dụng treo khi INSERT/UPDATE, log:
  "canceling statement due to conflicts with recovery" hoặc
  Patroni log: "Sync standby unavailable"

Nguyên nhân:
  synchronous_node_count=1 nhưng KHÔNG node nào ở state SyncStandby
  (node sync chết, các node còn lại nosync=true)

Xử lý:
  1. patronictl list -> xem state các node
  2. Khởi động lại node sync chết (ưu tiên)
  3. Nếu node đó không sửa được: bỏ tag nosync trên node healthy khác
       patronictl edit-config -> sửa tags
  4. Tạm thời (mất đồng bộ, RPO>0): synchronous_mode=false qua edit-config
     -> CHỈ khi chấp nhận mất ghi đồng bộ và đã cảnh báo application
```

### 8.3 Replica lag quá lớn

```text
Triệu chứng: patronictl list "Lag in MB" tăng / replay_lag lớn

Nguyên nhân:
  - Network chậm
  - Primary ghi WAL quá nhanh (bulk load)
  - Replica đang chạy query nặng / checkpoint lâu
  - Replication slot không consume (replica dừng)
  - max_wal_senders hết -> replica không kết nối được

Xử lý:
  1. SELECT * FROM pg_stat_replication; (state != streaming?)
  2. Kiểm tra disk replica, log PG replica
  3. Kiểm tra slot: pg_replication_slots
  4. bulk load nên chạy qua replica/nơi ít quan trọng, chia nhỏ batch
```

### 8.4 Split-brain (2 primary)

```text
Triệu chứng:
  2 node cùng trả pg_is_in_recovery() = false
  or log "conflicting timelines"

Nguyên nhân phổ biến:
  - Failover thủ công khi primary còn sống
  - Network partition + Patroni trên cả 2 phía đều promote (hiếm khi có split-brain đúng nghĩa vì dùng DCS)
  - Khởi động PostgreSQL tay (pg_ctl start) ngoài Patroni

Xử lý:
  1. DỨT kết nối application khỏi node sai (đóng firewall/VIP)
  2. Dừng Patroni + PostgreSQL trên node "thua"
  3. Xác định primary hợp lệ (theo leader key trong etcd)
  4. Node thua: xóa data, để Patroni pg_basebackup lại
     HOẶC pg_rewind nếu còn cùng timeline
  5. Rút kinh nghiệm: KHÔNG start PG ngoài Patroni
```

### 8.5 Node cũ không rejoin sau failover

```text
Triệu chứng: pg_rewind fail / timeline mismatch

Nguyên nhân:
  - use_pg_rewind=false (hiện tại = true, ok)
  - wal_log_hints=off (hiện tại = on, ok)
  - Node cũ có WAL không có trên primary mới (trùng slot/TU)
  - Mất dữ liệu WAL cần cho rewind

Xử lý:
  1. Dừng patroni node cũ
  2. Thử pg_rewind thủ công nếu có thể
  3. Không được: xóa data_dir -> để Patroni basebackup lại
```

### 8.6 etcd mất quorum

```text
Triệu chứng: mọi Patroni log "etcd" connection errors, không renew leader

Xử lý:
  1. Khôi phục tối thiểu 2/3 etcd member
  2. Nếu member mất hoàn toàn: etcd member remove rồi add lại
  3. Cân nhắc: etcd 3 node nên đặt trên 3 máy KHÁC HA cluster
     (hiện etcd chung node với PG -> cùng lúc PG chết thì etcd cũng chết)
```

---

## 9. Lưu ý bảo mật

```text
Hiện tại trong patroni.yaml:
  - password superuser/replication hardcode plaintext
  - restapi listen 0.0.0.0:8008 (không auth)
  - pg_hba host all all 0.0.0.0/0 scram-sha-256 (mở rộng, chỉ chặn ở firewall)

Khuyến nghị:
  1. file patroni.yaml: chmod 600, owner root (hoặc postgres)
  2. secret lưu ngoài file (vault/env), hoặc tối thiểu tách file secret riêng
  3. restapi chỉ bind localhost hoặc firewall cho subnet quản trị
  4. etcd bật client cert auth / token
  5. firewall: chỉ mở 5432 cho app subnet, 8008/2379 cho subnet quản trị
  6. audit định kỳ password (đổi định kỳ)
```

---

## 10. Checklist vận hành cluster

### Khởi động / khởi tạo

```text
[ ] etcd 3 node healthy
[ ] Node 1 khởi động Patroni trước -> bootstrap Leader
[ ] Node 2, 3 khởi động -> tự động thành Replica
[ ] patronictl list: 1 Leader + 2 Replica (1 SyncStandby)
[ ] pg_is_in_recovery() đúng vai trò từng node
[ ] pg_stat_replication trên primary: 2 dòng streaming
[ ] archive hoạt động: pg_stat_archiver.failed_count = 0
```

### Hàng ngày

```text
[ ] patronictl list: Leader ổn định, không flap
[ ] Lag ~0, không tăng dần
[ ] SyncStandby >= 1 (bắt buộc với strict mode)
[ ] etcd quorum 3/3
[ ] Disk data/WAL/repo còn dung lượng
[ ] Backup pgBackRest OK (xem pgbackrest_runbook.md)
[ ] Log không tràn warning liên tục
```

### Trước failover/switchover

```text
[ ] Xác định node candidate (lag nhỏ, sync)
[ ] Thông báo downtime cho application
[ ] Backup/mở WAL archive check
[ ] Chạy switchover (KHÔNG failover nếu primary còn sống)
[ ] Verify: patronictl list, app kết nối lại, replication OK
```

### Sau failover

```text
[ ] Leader mới đúng kỳ vọng
[ ] Sync mode quay lại SyncStandby
[ ] Node cũ hồi phục -> Replica (pg_rewind / rebuild)
[ ] Replication slots đúng, không slot thừa
[ ] App kết nối lại bình thường
[ ] Ghi incident: thời gian, nguyên nhân, RTO/RPO thực tế
```

---

## 11. Tóm tắt

```text
Patroni = agent + DCS, không phải proxy.

- Leader election   : TTL lease trong etcd (ttl=30, loop_wait=10)
- Failover          : key hết hạn -> node lag <= 1MB tự promote (~30-45s)
- Sync replication  : synchronous_mode + strict + node_count=1
                      -> RPO=0 nhưng thiếu sync standby thì BLOCK write
- Cấu hình động     : patronictl edit-config (ưu tiên) thay vì sửa file lẻ
- pg_rewind         : node cũ rejoin nhanh sau failover
- Backup            : WAL archive qua pgBackRest (link pgbackrest_runbook.md)

Nguyên tắc vàng:
  1. KHÔNG khởi động PostgreSQL ngoài Patroni
  2. KHÔNG failover khi primary còn sống (dùng switchover)
  3. LUÔN monitor Leader + SyncStandby + Archiver + Slot
```

Tài liệu liên quan:

- [postgres_fundamentals.md](postgres_fundamentals.md)
- [postgres_design_analysis.md](postgres_design_analysis.md)
- [pgbackrest_runbook.md](pgbackrest_runbook.md)
- Config thực tế: `config/node 1/patroni.yaml`, `config/node2/patroni.yaml`, `config/node3/patroni.yaml`

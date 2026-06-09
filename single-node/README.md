# PostgreSQL High Availability với Patroni

Hệ thống PostgreSQL HA sử dụng Patroni + etcd + HAProxy + PgBouncer, triển khai bằng Docker Compose. Đảm bảo tự động failover khi primary gặp sự cố, không cần can thiệp thủ công.

---

## Mục lục

- [Kiến trúc tổng quan](#kiến-trúc-tổng-quan)
- [Thành phần](#thành-phần)
- [Luồng hoạt động](#luồng-hoạt-động)
- [Cấu trúc thư mục](#cấu-trúc-thư-mục)
- [Yêu cầu](#yêu-cầu)
- [Cách chạy](#cách-chạy)
- [Endpoints](#endpoints)
- [Vận hành](#vận-hành)
- [Lưu ý quan trọng](#lưu-ý-quan-trọng)
- [Troubleshooting](#troubleshooting)

---

## Kiến trúc tổng quan

```
                        ┌─────────────────────────────┐
                        │        Application          │
                        └──────────────┬──────────────┘
                                       │ :6432
                        ┌──────────────▼──────────────┐
                        │          PgBouncer          │
                        │      Connection Pooling      │
                        └──────────────┬──────────────┘
                                       │ :5000 / :5001
                        ┌──────────────▼──────────────┐
                        │           HAProxy           │
                        │     Health Check via REST   │
                        │   /primary  →  port 5000    │
                        │   /replica  →  port 5001    │
                        └──┬──────────┬──────────┬───┘
                           │          │          │
               ┌───────────▼─┐  ┌─────▼──────┐  ┌▼───────────┐
               │  Patroni-1  │  │  Patroni-2 │  │  Patroni-3 │
               │  (Leader)   │  │  (Replica) │  │  (Replica) │
               │  PostgreSQL │  │ PostgreSQL │  │ PostgreSQL │
               │  :5432      │  │ :5432      │  │ :5432      │
               └──────┬──────┘  └─────┬──────┘  └─────┬──────┘
                      │  WAL stream   │                │
                      └───────────────┴────────────────┘
                                      │ heartbeat / lock
               ┌───────────┬──────────▼──────────┬───────────┐
               │  etcd-1   │       etcd-2         │  etcd-3   │
               │  :2379    │       :2379          │  :2379    │
               └───────────┴─────────────────────┴───────────┘
```

---

## Thành phần

### etcd (3 node)
Distributed key-value store, đóng vai trò **distributed lock** cho Patroni. Chỉ node nào giữ được lock trên etcd mới được phép làm primary. Cần 3 node để đảm bảo **quorum** (n/2 + 1 = 2): khi 1 node chết, 2 node còn lại vẫn vote được và cluster vẫn hoạt động.

### Patroni (3 node)
Orchestrator quản lý vòng đời của PostgreSQL cluster:
- Chạy `initdb` và bootstrap cluster lần đầu
- Liên tục ghi heartbeat lên etcd (mặc định mỗi 10s)
- Khi primary chết, các replica race lên etcd giành lock → node thắng tự `pg_ctl promote` lên thành primary mới
- Expose REST API tại `:8008` để HAProxy health check

| Endpoint REST | Ý nghĩa |
|---|---|
| `GET /primary` | HTTP 200 nếu node đang là primary |
| `GET /replica` | HTTP 200 nếu node đang là replica |
| `GET /health`  | HTTP 200 nếu node healthy (bất kể role) |

### HAProxy
Load balancer định tuyến connection đến đúng node:
- **Port 5000**: chỉ route đến primary (write)
- **Port 5001**: route đến replica theo round-robin (read-only)
- Dùng `httpchk` để gọi REST API của Patroni mỗi 3s, tự loại node chết ra khỏi pool

### PgBouncer
Connection pooler ngồi trước HAProxy:
- **Port 6432**: endpoint duy nhất cho application
- Mode `transaction`: mỗi transaction mượn một connection thật, trả lại sau khi xong → giảm số connection thật vào PostgreSQL
- Giúp hệ thống chịu được nhiều concurrent client mà không làm PostgreSQL quá tải

---

## Luồng hoạt động

### Khi hệ thống bình thường

```
App → PgBouncer:6432 → HAProxy:5000 → Patroni-1 (primary) :5432
                     → HAProxy:5001 → Patroni-2/3 (replica) :5432
```

### Khi primary gặp sự cố (auto failover)

```
t=0s   Patroni-1 (primary) chết
t=10s  Patroni-2 và Patroni-3 hết TTL heartbeat, detect mất leader
t=10s  Cả hai race lên etcd giành lock
t=12s  Patroni-2 thắng → chạy pg_ctl promote
t=13s  PostgreSQL trên Patroni-2 trở thành primary
t=15s  HAProxy gọi /primary → Patroni-2 trả về 200, Patroni-3 trả về 503
t=15s  HAProxy tự route traffic sang Patroni-2
       → Downtime thực tế: ~10–15 giây
```

### Khi primary cũ quay lại

```
Patroni-1 start → detect đã có leader mới trên etcd
              → tự join lại cluster với role Replica
              → pg_basebackup từ primary mới
              → bắt đầu streaming replication
```

---

## Cấu trúc thư mục

```
single-node/
├── deploy.sh                  # Script deploy tự động
├── test_failover.py           # Script test failover
├── docker-compose.yml
│
├── patroni/
│   ├── Dockerfile             # Image: postgres:15-alpine + patroni
│   ├── entrypoint.sh          # Fix permission + su-exec postgres
│   ├── patroni-1.yml
│   ├── patroni-2.yml
│   └── patroni-3.yml
│
├── haproxy/
│   └── haproxy.cfg
│
├── pgbouncer/
│   ├── pgbouncer.ini
│   └── userlist.txt           # Credentials cho PgBouncer
│
└── data/                      # PostgreSQL data (mount ra disk)
    ├── patroni-1/
    ├── patroni-2/
    └── patroni-3/
```

---

## Yêu cầu

- Docker Engine >= 24.0
- Docker Compose >= 2.20
- `psql` client (để test kết nối)
- Python 3.10+ với `psycopg2-binary` (để chạy test failover)
- RAM: tối thiểu 4GB (mỗi PostgreSQL instance ~512MB)
- Disk: tối thiểu 10GB trống

---

## Cách chạy

### Deploy lần đầu

```bash
cd single-node/
chmod +x deploy.sh
./deploy.sh
```

Script tự động chạy theo thứ tự:
1. Cleanup container và volume cũ
2. Build Patroni image
3. Start etcd cluster (chờ healthy)
4. Start Patroni-1, chờ bầu leader xong mới start Patroni-2/3
5. Start HAProxy
6. Start PgBouncer
7. Verify kết nối và in summary

### Deploy nhanh (bỏ qua build)

```bash
./deploy.sh --skip-build
```

### Teardown

```bash
docker compose down -v    # xóa cả volume (mất data)
docker compose down       # giữ lại volume (giữ data)
```

---

## Endpoints

| Endpoint | Port | Mục đích |
|---|---|---|
| PgBouncer | 6432 | **App kết nối vào đây** (primary, read/write) |
| HAProxy primary | 5000 | Primary trực tiếp (read/write) |
| HAProxy replica | 5001 | Replica round-robin (read-only) |
| HAProxy stats | 7000 | Dashboard web HAProxy |
| Patroni REST | 8008 | Health check, cluster info |

### Kết nối từ application

```
DATABASE_URL=postgresql://postgres:postgres_pass@localhost:6432/postgres
```

---

## Vận hành

### Xem trạng thái cluster

```bash
docker compose exec patroni-1 patronictl -c /etc/patroni/patroni.yml list
```

Kết quả mẫu:
```
+ Cluster: cluster1 ──────────+─────────+────+─────────────+─────+
| Member    | Host      | Role    | State     | TL | Receive LSN | Lag |
+-----------+-----------+---------+-----------+----+-------------+-----+
| patroni-1 | patroni-1 | Leader  | running   |  1 |             |     |
| patroni-2 | patroni-2 | Replica | streaming |  1 |  0/40455C0  |   0 |
| patroni-3 | patroni-3 | Replica | streaming |  1 |  0/40455C0  |   0 |
```

### Kết nối DB

```bash
# Qua PgBouncer (khuyến nghị)
PGPASSWORD=postgres_pass psql -h localhost -p 6432 -U postgres

# Trực tiếp vào primary
PGPASSWORD=postgres_pass psql -h localhost -p 5000 -U postgres

# Trực tiếp vào replica
PGPASSWORD=postgres_pass psql -h localhost -p 5001 -U postgres
```

### Kiểm tra replication

```bash
# Kiểm tra data đồng bộ trên cả 3 node
docker compose exec patroni-1 psql -U postgres -c "SELECT COUNT(*) FROM <table>;"
docker compose exec patroni-2 psql -U postgres -c "SELECT COUNT(*) FROM <table>;"
docker compose exec patroni-3 psql -U postgres -c "SELECT COUNT(*) FROM <table>;"
```

### Test failover thủ công

```bash
# Stop primary
docker compose stop patroni-1

# Chờ ~15s, kiểm tra leader mới
docker compose exec patroni-2 patronictl -c /etc/patroni/patroni.yml list

# Start lại, tự join thành replica
docker compose start patroni-1
```

### Test failover tự động với script

```bash
pip install psycopg2-binary
python3 test_failover.py
```

### Switchover có kiểm soát (không mất data)

```bash
# Chuyển leadership sang patroni-2
docker compose exec patroni-1 \
    patronictl -c /etc/patroni/patroni.yml switchover \
    --master patroni-1 --candidate patroni-2 --force
```

### Xem HAProxy stats

Mở trình duyệt: `http://localhost:7000`

---

## Lưu ý quan trọng

### 1. etcd quorum
etcd cần quá bán số node sống để hoạt động. Với 3 node, chịu được tối đa **1 node chết**. Nếu 2 node etcd chết cùng lúc, cluster mất quorum → Patroni không thể thực hiện failover.

### 2. Replica lag
Nếu replica lag quá lớn (vượt `maximum_lag_on_failover = 1048576` bytes ~ 1MB), Patroni sẽ **không promote** replica đó để tránh mất data. Theo dõi lag qua `patronictl list`.

### 3. PgBouncer userlist.txt
Password trong `userlist.txt` phải ở dạng **plaintext** khi PostgreSQL dùng `scram-sha-256`. Nếu dùng md5 hash sẽ bị lỗi `wrong password type`.

### 4. Permission data directory
Data directory `/var/lib/postgresql/data` phải có permission `0750` và owner là user `postgres`. Nếu mount volume mới, `entrypoint.sh` tự fix permission trước khi start Patroni.

### 5. Thứ tự khởi động
Patroni-1 phải được start và bootstrap xong trước khi start Patroni-2/3. Nếu start đồng thời, các node có thể race condition khi khởi tạo cluster. Script `deploy.sh` đã xử lý thứ tự này tự động.

### 6. Downtime trong failover
Downtime khoảng **10–15 giây** trong lúc bầu leader mới. Application cần implement retry logic khi kết nối thất bại. Cấu hình trong `patroni.yml`:
- `ttl: 30` — thời gian lock hết hạn
- `loop_wait: 10` — chu kỳ Patroni check
- `retry_timeout: 10` — timeout cho các operation

### 7. Không dùng port 5432 trực tiếp
Application **không nên** kết nối thẳng vào port 5432 của từng Patroni node. Luôn kết nối qua PgBouncer (6432) hoặc HAProxy (5000/5001) để đảm bảo traffic tự động được route đến đúng node.

### 8. Volume và data
Data được mount ra `./data/patroni-X/`. Thư mục này thuộc sở hữu của user `postgres` trong container (uid 999), nên host user không thể `cd` trực tiếp vào. Dùng `docker compose exec` để truy cập data.

---

## Troubleshooting

### etcd không form cluster
```bash
# Kiểm tra biến môi trường ETCD_INITIAL_CLUSTER không có dấu cách sau dấu phẩy
docker compose exec etcd-1 env | grep ETCD_INITIAL_CLUSTER

# Xóa volume và chạy lại
docker compose down -v && ./deploy.sh
```

### Patroni không bootstrap
```bash
# Xem log chi tiết
docker compose logs patroni-1 2>&1 | head -60

# Nguyên nhân thường gặp:
# - bin_dir sai → kiểm tra: docker run --rm <image> find /usr -name initdb
# - Chạy với root → cần USER postgres trong Dockerfile + su-exec trong entrypoint
# - Volume cũ còn data → docker compose down -v
```

### PgBouncer lỗi authentication
```bash
# Kiểm tra auth_type trong pgbouncer.ini phải là scram-sha-256
# Kiểm tra userlist.txt phải dùng plaintext password:
cat pgbouncer/userlist.txt
# Đúng:  "postgres" "postgres_pass"
# Sai:   "postgres" "md5xxxxxxxxxxxx"
```

### HAProxy restart liên tục
```bash
# Kiểm tra config syntax
docker compose logs haproxy | grep ALERT

# Thường do thiếu newline cuối file
echo "" >> haproxy/haproxy.cfg
docker compose restart haproxy
```

### Replica không streaming
```bash
# Kiểm tra pg_hba.conf có cho phép replication không
docker compose exec patroni-1 psql -U postgres -c "SELECT * FROM pg_hba_file_rules WHERE database = '{replication}';"

# Kiểm tra replication slot
docker compose exec patroni-1 psql -U postgres -c "SELECT * FROM pg_replication_slots;"
```

### Note

```bash
#Cấp quyền, chạy file .sh
chmod +x deploy.sh
./deploy.sh
```

```bash
#Kiểm tra trạng thái node
docker compose exec patroni-2 patronictl -c /etc/patroni/patroni.yml list
```

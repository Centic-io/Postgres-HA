# PostgreSQL HA — Multi Node

Triển khai PostgreSQL High Availability trên 4 máy thật với Patroni + etcd + HAProxy + PgBouncer.

---

## Kiến trúc

```
                    ┌─────────────────────────┐
                    │       Application       │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  NODE4 — 10.0.0.4       │
                    │  PgBouncer :6432        │
                    │  HAProxy   :5000/:5001  │
                    └──┬──────────┬──────────┘
                       │          │
          ┌────────────▼─┐   ┌────▼────────────┐   ┌─────────────────┐
          │ NODE1        │   │ NODE2            │   │ NODE3           │
          │ 10.0.0.1     │   │ 10.0.0.2        │   │ 10.0.0.3        │
          │ etcd :2379   │   │ etcd :2379      │   │ etcd :2379      │
          │ Patroni:8008 │   │ Patroni :8008   │   │ Patroni :8008   │
          │ PG    :5432  │   │ PG     :5432    │   │ PG     :5432    │
          └──────────────┘   └─────────────────┘   └─────────────────┘
```

---

## Cấu trúc thư mục

```
multi-node/
├── deploy.sh                    # Script deploy — chạy trên từng máy
│
├── node1/
│   └── docker-compose.yml       # etcd + Patroni cho node1
├── node2/
│   └── docker-compose.yml       # etcd + Patroni cho node2
├── node3/
│   └── docker-compose.yml       # etcd + Patroni cho node3
├── node4/
│   └── docker-compose.yml       # HAProxy + PgBouncer
│
└── shared/
    ├── patroni/
    │   ├── Dockerfile
    │   ├── entrypoint.sh
    │   ├── patroni-node1.yml
    │   ├── patroni-node2.yml
    │   └── patroni-node3.yml
    ├── haproxy/
    │   └── haproxy.cfg
    └── pgbouncer/
        ├── pgbouncer.ini
        └── userlist.txt
```

---

## Yêu cầu

- 4 máy (VM hoặc bare-metal), Ubuntu 22.04+
- Docker Engine >= 24.0, Docker Compose >= 2.20
- Các máy thông nhau qua mạng nội bộ (ping được)
- Port mở giữa các node:

| Port | Service | Chiều |
|------|---------|-------|
| 2379 | etcd client | node1/2/3 ↔ node1/2/3 |
| 2380 | etcd peer   | node1/2/3 ↔ node1/2/3 |
| 5432 | PostgreSQL  | node4 → node1/2/3 |
| 8008 | Patroni REST| node4 → node1/2/3 |
| 5000 | HAProxy primary | app → node4 |
| 5001 | HAProxy replica | app → node4 |
| 6432 | PgBouncer   | app → node4 |

---

## Cách deploy

### Bước 1 — Copy code lên từng máy

```bash
# Trên máy local, copy toàn bộ thư mục multi-node lên 4 máy
scp -r multi-node/ user@10.0.0.1:~/postgres-ha/
scp -r multi-node/ user@10.0.0.2:~/postgres-ha/
scp -r multi-node/ user@10.0.0.3:~/postgres-ha/
scp -r multi-node/ user@10.0.0.4:~/postgres-ha/
```

### Bước 2 — Thay IP thật vào config (nếu dùng placeholder)

Tìm và thay toàn bộ `10.0.0.1`, `10.0.0.2`, `10.0.0.3`, `10.0.0.4` bằng IP thật:

```bash
# Chạy trên máy local trước khi scp
sed -i 's/10\.0\.0\.1/<IP_NODE1>/g' shared/patroni/patroni-node1.yml node1/docker-compose.yml
sed -i 's/10\.0\.0\.2/<IP_NODE2>/g' shared/patroni/patroni-node2.yml node2/docker-compose.yml
sed -i 's/10\.0\.0\.3/<IP_NODE3>/g' shared/patroni/patroni-node3.yml node3/docker-compose.yml
sed -i 's/10\.0\.0\.4/<IP_NODE4>/g' shared/haproxy/haproxy.cfg shared/pgbouncer/pgbouncer.ini node4/docker-compose.yml
```

### Bước 3 — Deploy node1 (bootstrap cluster)

```bash
# SSH vào node1
ssh user@10.0.0.1
cd ~/postgres-ha/multi-node
chmod +x deploy.sh
./deploy.sh 1
```

Chờ đến khi thấy log `Leader: patroni-node1` trước khi tiếp tục.

### Bước 4 — Deploy node2 và node3

Chạy đồng thời hoặc tuần tự trên node2 và node3:

```bash
# Trên node2
ssh user@10.0.0.2
cd ~/postgres-ha/multi-node && ./deploy.sh 2

# Trên node3
ssh user@10.0.0.3
cd ~/postgres-ha/multi-node && ./deploy.sh 3
```

### Bước 5 — Verify cluster

```bash
# Từ node1 (hoặc bất kỳ node nào)
docker compose -f node1/docker-compose.yml exec patroni \
    patronictl -c /etc/patroni/patroni.yml list
```

Kết quả mong đợi:
```
+ Cluster: pg-cluster ──────────+─────────+────+─────────────+─────+
| Member         | Host       | Role    | State     | TL | Lag |
+────────────────+────────────+─────────+───────────+────+─────+
| patroni-node1  | 10.0.0.1   | Leader  | running   |  1 |     |
| patroni-node2  | 10.0.0.2   | Replica | streaming |  1 |   0 |
| patroni-node3  | 10.0.0.3   | Replica | streaming |  1 |   0 |
```

### Bước 6 — Deploy node4 (HAProxy + PgBouncer)

```bash
ssh user@10.0.0.4
cd ~/postgres-ha/multi-node && ./deploy.sh 4
```

---

## Vận hành

### Xem cluster status

```bash
# Từ node1
docker compose -f node1/docker-compose.yml exec patroni \
    patronictl -c /etc/patroni/patroni.yml list

# Hoặc qua REST API (từ bất kỳ máy nào)
curl http://10.0.0.1:8008/cluster | python3 -m json.tool
```

### Kết nối DB

```bash
# Qua PgBouncer (khuyến nghị cho app)
PGPASSWORD=postgres_pass psql -h 10.0.0.4 -p 6432 -U postgres

# Trực tiếp primary
PGPASSWORD=postgres_pass psql -h 10.0.0.4 -p 5000 -U postgres

# Trực tiếp replica
PGPASSWORD=postgres_pass psql -h 10.0.0.4 -p 5001 -U postgres
```

### Switchover có kiểm soát

```bash
docker compose -f node1/docker-compose.yml exec patroni \
    patronictl -c /etc/patroni/patroni.yml switchover \
    --master patroni-node1 --candidate patroni-node2 --force
```

### Restart một node

```bash
# Trên node cần restart
docker compose -f node2/docker-compose.yml restart patroni
```

### Teardown một node

```bash
docker compose -f node1/docker-compose.yml down -v
```

---

## Lưu ý quan trọng

### Thứ tự deploy
Node1 **phải** được deploy và bootstrap xong trước khi start node2/3. Nếu start đồng thời, các node sẽ race condition khi khởi tạo cluster.

### ETCD_INITIAL_CLUSTER_STATE
Tất cả 3 node đều dùng `"new"` lần đầu deploy. Nếu sau này cần add thêm node hoặc replace node, đổi thành `"existing"`.

### network_mode: host
Multi-node dùng `network_mode: host` thay vì Docker bridge network, vì các container cần giao tiếp qua IP thật của máy vật lý. Điều này khác với single-node dùng Docker bridge.

### Firewall
Đảm bảo các port 2379, 2380, 5432, 8008 được mở giữa các node:
```bash
# Ubuntu/ufw
ufw allow from 10.0.0.0/24 to any port 2379
ufw allow from 10.0.0.0/24 to any port 2380
ufw allow from 10.0.0.0/24 to any port 5432
ufw allow from 10.0.0.0/24 to any port 8008
```

### Data directory
Data PostgreSQL lưu trong Docker named volume `patroni-data` trên mỗi node. Để mount ra disk:
```yaml
# Trong node1/docker-compose.yml, đổi:
volumes:
  - patroni-data:/var/lib/postgresql/data
# Thành:
  - ./data:/var/lib/postgresql/data
```

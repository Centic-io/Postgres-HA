#!/bin/bash

# Script deploy multi-node PostgreSQL HA
# Chạy trên từng máy tương ứng với NODE_NUM
#
# Cách dùng:
#   ./deploy.sh 1   → chạy trên node1 (10.0.0.1)
#   ./deploy.sh 2   → chạy trên node2 (10.0.0.2)
#   ./deploy.sh 3   → chạy trên node3 (10.0.0.3)
#   ./deploy.sh 4   → chạy trên node4 (10.0.0.4) — HAProxy + PgBouncer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_NUM="${1:-}"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
info()   { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ $1${NC}"; }
header() { echo -e "\n${BLUE}════════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}════════════════════════════════════════${NC}"; }

# ─── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$NODE_NUM" ]]; then
    error "Thiếu tham số NODE_NUM. Dùng: ./deploy.sh <1|2|3|4>"
fi

if [[ ! "$NODE_NUM" =~ ^[1-4]$ ]]; then
    error "NODE_NUM phải là 1, 2, 3 hoặc 4"
fi

NODE_DIR="$SCRIPT_DIR/node${NODE_NUM}"
if [[ ! -d "$NODE_DIR" ]]; then
    error "Thư mục $NODE_DIR không tồn tại"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
wait_healthy() {
    local service=$1
    local compose_dir=$2
    local max_wait=${3:-90}
    local elapsed=0

    info "Chờ $service healthy..."
    while [ $elapsed -lt $max_wait ]; do
        status=$(docker compose -f "$compose_dir/docker-compose.yml" ps "$service" \
            --format json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Health',''))" \
            2>/dev/null || echo "")

        if [ "$status" = "healthy" ]; then
            log "$service healthy"
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
        echo -ne "\r  ${YELLOW}Waiting $service... ${elapsed}s / ${max_wait}s${NC}   "
    done
    echo ""
    warn "$service chưa healthy sau ${max_wait}s — tiếp tục..."
}

wait_patroni_leader() {
    local node_ip=$1
    local max_wait=${2:-120}
    local elapsed=0

    info "Chờ Patroni leader tại $node_ip..."
    while [ $elapsed -lt $max_wait ]; do
        leader=$(curl -sf "http://$node_ip:8008/cluster" 2>/dev/null \
            | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    members = d.get('members', [])
    leaders = [m['name'] for m in members if m.get('role') == 'leader']
    print(leaders[0] if leaders else '')
except:
    print('')
" 2>/dev/null || echo "")

        if [ -n "$leader" ]; then
            echo ""
            log "Leader: $leader"
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
        echo -ne "\r  ${YELLOW}Waiting for leader... ${elapsed}s / ${max_wait}s${NC}   "
    done
    echo ""
    warn "Chưa thấy leader sau ${max_wait}s"
}

# ─── Deploy node 1/2/3 (etcd + Patroni) ──────────────────────────────────────
deploy_patroni_node() {
    local node_ip
    case $NODE_NUM in
        1) node_ip="10.0.0.1" ;;
        2) node_ip="10.0.0.2" ;;
        3) node_ip="10.0.0.3" ;;
    esac

    header "DEPLOY NODE${NODE_NUM} — etcd + Patroni ($node_ip)"

    # Build image
    info "Build Patroni image..."
    docker compose -f "$NODE_DIR/docker-compose.yml" build --no-cache patroni
    log "Build xong"

    # Cleanup
    info "Cleanup container cũ..."
    docker compose -f "$NODE_DIR/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true

    # Start etcd
    header "Start etcd"
    docker compose -f "$NODE_DIR/docker-compose.yml" up -d etcd
    wait_healthy etcd "$NODE_DIR" 60

    # Verify etcd
    sleep 5
    info "Verify etcd endpoint..."
    if curl -sf "http://$node_ip:2379/health" | grep -q "true"; then
        log "etcd healthy tại $node_ip:2379"
    else
        warn "etcd chưa respond, tiếp tục..."
    fi

    # Start Patroni
    header "Start Patroni"
    if [ "$NODE_NUM" = "1" ]; then
        warn "Node1 sẽ bootstrap cluster. Đảm bảo node2 và node3 chưa chạy."
        warn "Nếu đây là lần deploy đầu, chạy node1 trước, chờ leader, rồi mới chạy node2/3."
    fi

    docker compose -f "$NODE_DIR/docker-compose.yml" up -d patroni
    wait_healthy patroni "$NODE_DIR" 90

    if [ "$NODE_NUM" = "1" ]; then
        wait_patroni_leader "$node_ip"
    fi

    # Summary
    header "NODE${NODE_NUM} DEPLOYED"
    docker compose -f "$NODE_DIR/docker-compose.yml" ps
    echo ""
    info "Patroni REST API: http://$node_ip:8008"
    info "PostgreSQL:       $node_ip:5432"
    info "etcd:             $node_ip:2379"
}

# ─── Deploy node4 (HAProxy + PgBouncer) ───────────────────────────────────────
deploy_proxy_node() {
    header "DEPLOY NODE4 — HAProxy + PgBouncer (10.0.0.4)"

    # Cleanup
    info "Cleanup container cũ..."
    docker compose -f "$NODE_DIR/docker-compose.yml" down --remove-orphans 2>/dev/null || true

    # Start
    docker compose -f "$NODE_DIR/docker-compose.yml" up -d
    sleep 5

    # Verify
    header "Verify"
    docker compose -f "$NODE_DIR/docker-compose.yml" ps

    echo ""
    info "Test HAProxy stats..."
    if curl -sf "http://localhost:7000" > /dev/null; then
        log "HAProxy stats: http://10.0.0.4:7000"
    else
        warn "HAProxy stats chưa respond"
    fi

    echo ""
    info "Test kết nối DB qua PgBouncer..."
    result=$(PGPASSWORD=postgres_pass psql \
        -h localhost -p 6432 -U postgres \
        -t -c "SELECT 'OK: ' || inet_server_addr();" 2>/dev/null | tr -d ' \n' || echo "FAILED")

    if [[ "$result" == OK:* ]]; then
        log "PgBouncer → $result"
    else
        warn "PgBouncer chưa kết nối được DB. Đảm bảo node1/2/3 đã chạy trước."
    fi

    header "NODE4 DEPLOYED"
    echo -e "
  ${GREEN}Endpoints:${NC}
    PgBouncer (app)  → 10.0.0.4:6432  (primary, read/write)
    HAProxy primary  → 10.0.0.4:5000  (primary, read/write)
    HAProxy replica  → 10.0.0.4:5001  (replica, read-only)
    HAProxy stats    → http://10.0.0.4:7000

  ${GREEN}App kết nối:${NC}
    DATABASE_URL=postgresql://postgres:postgres_pass@10.0.0.4:6432/postgres
"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
header "POSTGRESQL HA — MULTI NODE DEPLOY"
info "Node: $NODE_NUM | Dir: $NODE_DIR"

case $NODE_NUM in
    1|2|3) deploy_patroni_node ;;
    4)     deploy_proxy_node ;;
esac

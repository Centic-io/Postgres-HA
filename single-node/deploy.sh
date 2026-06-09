#!/bin/bash

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$COMPOSE_DIR"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
info()   { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ $1${NC}"; }
header() {
    echo -e "\n${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
}

# ─── Wait helpers ─────────────────────────────────────────────────────────────
wait_healthy() {
    local service=$1
    local max_wait=${2:-60}
    local elapsed=0

    info "Chờ $service healthy..."
    while [ $elapsed -lt $max_wait ]; do
        status=$(docker compose ps "$service" --format json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Health',''))" 2>/dev/null || echo "")

        if [ "$status" = "healthy" ]; then
            log "$service healthy"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
        echo -ne "\r  ${YELLOW}Waiting $service... ${elapsed}s / ${max_wait}s${NC}   "
    done
    echo ""
    warn "$service chưa healthy sau ${max_wait}s, tiếp tục..."
}

wait_patroni_leader() {
    local max_wait=${1:-90}
    local elapsed=0

    info "Chờ Patroni cluster bầu leader..."
    while [ $elapsed -lt $max_wait ]; do
        leader=$(docker compose exec -T patroni-1 \
            patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
            | grep "Leader" | awk '{print $2}' || echo "")

        if [ -n "$leader" ]; then
            echo ""
            log "Leader đã được bầu: $leader"
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
        echo -ne "\r  ${YELLOW}Waiting for leader... ${elapsed}s / ${max_wait}s${NC}   "
    done
    echo ""
    warn "Chưa có leader sau ${max_wait}s"
}

wait_replicas_streaming() {
    local max_wait=${1:-60}
    local elapsed=0

    info "Chờ replica streaming..."
    while [ $elapsed -lt $max_wait ]; do
        streaming=$(docker compose exec -T patroni-1 \
            patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
            | grep -c "streaming" || echo "0")

        if [ "$streaming" -ge 2 ]; then
            echo ""
            log "Cả 2 replica đang streaming"
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
        echo -ne "\r  ${YELLOW}Streaming replicas: ${streaming}/2 — ${elapsed}s / ${max_wait}s${NC}   "
    done
    echo ""
    warn "Replica chưa đủ sau ${max_wait}s"
}

# ─── Steps ────────────────────────────────────────────────────────────────────
step_cleanup() {
    header "STEP 0 — Cleanup"
    warn "Xóa toàn bộ container và volume cũ..."
    docker compose down -v --remove-orphans 2>/dev/null || true
    log "Cleanup xong"
}

step_build() {
    header "STEP 1 — Build images"
    info "Build Patroni image..."
    docker compose build --no-cache patroni-1 patroni-2 patroni-3
    log "Build xong"
}

step_etcd() {
    header "STEP 2 — Start etcd cluster"
    docker compose up -d etcd-1 etcd-2 etcd-3

    wait_healthy etcd-1 60
    wait_healthy etcd-2 60
    wait_healthy etcd-3 60

    # Verify etcd cluster
    info "Verify etcd cluster..."
    sleep 5
    member_count=$(docker compose exec -T etcd-1 \
        etcdctl member list 2>/dev/null | wc -l | tr -d ' ')

    if [ "$member_count" -eq 3 ]; then
        log "etcd cluster OK — 3 members"
    else
        warn "etcd cluster có $member_count member (expected 3)"
    fi
}

step_patroni() {
    header "STEP 3 — Start Patroni cluster"

    # Start patroni-1 trước để bootstrap
    info "Start patroni-1 (bootstrap primary)..."
    docker compose up -d patroni-1
    wait_patroni_leader 90

    # Start replica sau khi có leader
    info "Start patroni-2 và patroni-3 (replica)..."
    docker compose up -d patroni-2 patroni-3
    wait_replicas_streaming 90
}

step_haproxy() {
    header "STEP 4 — Start HAProxy"
    docker compose up -d haproxy
    sleep 3

    # Verify HAProxy
    status=$(docker compose ps haproxy --format json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('State',''))" 2>/dev/null || echo "")

    if [ "$status" = "running" ]; then
        log "HAProxy running"
    else
        warn "HAProxy state: $status"
    fi
}

step_pgbouncer() {
    header "STEP 5 — Start PgBouncer"
    docker compose up -d pgbouncer
    sleep 3

    status=$(docker compose ps pgbouncer --format json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('State',''))" 2>/dev/null || echo "")

    if [ "$status" = "running" ]; then
        log "PgBouncer running"
    else
        warn "PgBouncer state: $status"
    fi
}

step_verify() {
    header "STEP 6 — Verify toàn bộ stack"

    echo ""
    info "Docker Compose status:"
    docker compose ps

    echo ""
    info "Patroni cluster:"
    docker compose exec -T patroni-1 \
        patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || warn "Không lấy được cluster info"

    echo ""
    info "Test kết nối qua PgBouncer (port 6432):"
    result=$(PGPASSWORD=postgres_pass psql \
        -h localhost -p 6432 -U postgres \
        -t -c "SELECT 'OK: ' || inet_server_addr();" 2>/dev/null | tr -d ' \n' || echo "FAILED")

    if [[ "$result" == OK:* ]]; then
        log "Kết nối PgBouncer thành công → $result"
    else
        warn "Kết nối PgBouncer thất bại — kiểm tra lại pgbouncer/userlist.txt"
    fi

    echo ""
    info "Test kết nối replica (port 5001):"
    result=$(PGPASSWORD=postgres_pass psql \
        -h localhost -p 5001 -U postgres \
        -t -c "SELECT 'OK replica: ' || inet_server_addr();" 2>/dev/null | tr -d ' \n' || echo "FAILED")

    if [[ "$result" == OK* ]]; then
        log "Kết nối replica thành công → $result"
    else
        warn "Kết nối replica thất bại"
    fi
}

summary() {
    header "DEPLOYMENT COMPLETE"
    echo -e "
  ${GREEN}Endpoints:${NC}
    PgBouncer (app)   → localhost:6432   (primary, read/write)
    HAProxy primary   → localhost:5000   (primary, read/write)
    HAProxy replica   → localhost:5001   (replica, read-only)
    HAProxy stats     → http://localhost:7000

  ${GREEN}Credentials:${NC}
    User: postgres
    Pass: postgres_pass

  ${GREEN}Useful commands:${NC}
    # Xem cluster status
    docker compose exec patroni-1 patronictl -c /etc/patroni/patroni.yml list

    # Kết nối DB
    PGPASSWORD=postgres_pass psql -h localhost -p 6432 -U postgres

    # Test failover
    python3 test_failover.py

    # Teardown
    docker compose down -v
"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    header "POSTGRESQL HA — AUTO DEPLOY"
    info "Working directory: $COMPOSE_DIR"

    # Parse args
    SKIP_BUILD=false
    SKIP_CLEANUP=false
    for arg in "$@"; do
        case $arg in
            --skip-build)   SKIP_BUILD=true ;;
            --skip-cleanup) SKIP_CLEANUP=true ;;
        esac
    done

    $SKIP_CLEANUP || step_cleanup
    $SKIP_BUILD   || step_build
    step_etcd
    step_patroni
    step_haproxy
    step_pgbouncer
    step_verify
    summary
}

main "$@"
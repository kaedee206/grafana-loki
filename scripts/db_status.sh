#!/usr/bin/env bash
# ==============================================================================
# DATABASE STATUS TEXTFILE COLLECTOR - db_status.sh
# Tự động phát hiện MySQL/PostgreSQL/Redis trong Docker
# Xuất metrics: db_status{type="mysql",status="running"} 1
#              db_status{type="mysql",status="available"} 0/1
#
# Nếu DB không có → metric value = 0 nhưng vẫn xuất (không phải N/A)
# Dashboard sẽ xử lý: if value = -1 → hiển thị "N/A"
# ==============================================================================

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/home/kaedee/monitoring/node_exporter_textfiles}"
OUTPUT_FILE="${OUTPUT_DIR}/db_status.prom"
TEMP_FILE="${OUTPUT_FILE}.tmp.$$"

mkdir -p "${OUTPUT_DIR}"
trap 'rm -f "${TEMP_FILE}"' EXIT

# ==============================================================================
# HELPER: Kiểm tra DB trong Docker
# ==============================================================================

# Kiểm tra container có đang chạy không
is_container_running() {
    local pattern="$1"
    docker ps --format '{{.Image}}\t{{.Names}}\t{{.Status}}' 2>/dev/null | \
        grep -iE "$pattern" | \
        grep -i "up" | \
        head -1
}

# Lấy port của container (first port mapping)
get_container_port() {
    local container_name="$1"
    local default_port="$2"
    docker port "$container_name" "$default_port" 2>/dev/null | \
        head -1 | \
        cut -d: -f2 || echo "$default_port"
}

# ==============================================================================
# CHECK MYSQL / MARIADB
# ==============================================================================
check_mysql() {
    local metric_name="db_mysql"
    local found=0
    local running=0
    local accessible=0
    local container_name=""
    local container_image=""
    local container_port=""
    
    # Tìm MySQL/MariaDB container
    local docker_info
    docker_info=$(docker ps --format '{{.Image}}\t{{.Names}}\t{{.Status}}' 2>/dev/null | \
        grep -iE "mysql|mariadb" || true)
    
    if [[ -n "$docker_info" ]]; then
        found=1
        container_image=$(echo "$docker_info" | head -1 | awk '{print $1}')
        container_name=$(echo "$docker_info" | head -1 | awk '{print $2}')
        local status=$(echo "$docker_info" | head -1 | awk '{print $3}')
        
        if echo "$status" | grep -qi "up"; then
            running=1
            
            # Thử kết nối MySQL để kiểm tra health
            if docker exec "$container_name" mysqladmin ping -h 127.0.0.1 --connect-timeout=3 \
               --silent 2>/dev/null; then
                accessible=1
            fi
        fi
    fi
    
    # Kiểm tra MySQL chạy trực tiếp trên host (không qua Docker)
    if [[ $found -eq 0 ]] && pgrep -x mysqld &>/dev/null; then
        found=1
        running=1
        container_name="host"
        container_image="mysql-host"
        if mysqladmin ping -h 127.0.0.1 --connect-timeout=3 --silent 2>/dev/null; then
            accessible=1
        fi
    fi
    
    echo "# HELP db_mysql_found 1 if MySQL/MariaDB is found (Docker or host)"
    echo "# TYPE db_mysql_found gauge"
    echo "db_mysql_found{container=\"${container_name:-none}\",image=\"${container_image:-none}\"} ${found}"
    
    echo "# HELP db_mysql_running 1 if MySQL/MariaDB container is running"
    echo "# TYPE db_mysql_running gauge"
    echo "db_mysql_running{container=\"${container_name:-none}\"} ${running}"
    
    echo "# HELP db_mysql_accessible 1 if MySQL/MariaDB is accepting connections"
    echo "# TYPE db_mysql_accessible gauge"
    echo "db_mysql_accessible{container=\"${container_name:-none}\"} ${accessible}"
}

# ==============================================================================
# CHECK POSTGRESQL
# ==============================================================================
check_postgresql() {
    local found=0
    local running=0
    local accessible=0
    local container_name=""
    local container_image=""
    
    local docker_info
    docker_info=$(docker ps --format '{{.Image}}\t{{.Names}}\t{{.Status}}' 2>/dev/null | \
        grep -iE "postgres|postgresql" || true)
    
    if [[ -n "$docker_info" ]]; then
        found=1
        container_image=$(echo "$docker_info" | head -1 | awk '{print $1}')
        container_name=$(echo "$docker_info" | head -1 | awk '{print $2}')
        local status=$(echo "$docker_info" | head -1 | awk '{print $3}')
        
        if echo "$status" | grep -qi "up"; then
            running=1
            
            # Thử pg_isready
            if docker exec "$container_name" pg_isready -h 127.0.0.1 \
               --timeout=3 2>/dev/null | grep -q "accepting connections"; then
                accessible=1
            fi
        fi
    fi
    
    # Kiểm tra PostgreSQL trên host
    if [[ $found -eq 0 ]] && pgrep -x postgres &>/dev/null; then
        found=1
        running=1
        container_name="host"
        container_image="postgresql-host"
        if pg_isready -h 127.0.0.1 --timeout=3 2>/dev/null | grep -q "accepting connections"; then
            accessible=1
        fi
    fi
    
    echo "# HELP db_postgresql_found 1 if PostgreSQL is found (Docker or host)"
    echo "# TYPE db_postgresql_found gauge"
    echo "db_postgresql_found{container=\"${container_name:-none}\",image=\"${container_image:-none}\"} ${found}"
    
    echo "# HELP db_postgresql_running 1 if PostgreSQL is running"
    echo "# TYPE db_postgresql_running gauge"
    echo "db_postgresql_running{container=\"${container_name:-none}\"} ${running}"
    
    echo "# HELP db_postgresql_accessible 1 if PostgreSQL is accepting connections"
    echo "# TYPE db_postgresql_accessible gauge"
    echo "db_postgresql_accessible{container=\"${container_name:-none}\"} ${accessible}"
}

# ==============================================================================
# CHECK REDIS
# ==============================================================================
check_redis() {
    local found=0
    local running=0
    local accessible=0
    local container_name=""
    local container_image=""
    
    local docker_info
    docker_info=$(docker ps --format '{{.Image}}\t{{.Names}}\t{{.Status}}' 2>/dev/null | \
        grep -iE "^redis|/redis" || true)
    
    if [[ -n "$docker_info" ]]; then
        found=1
        container_image=$(echo "$docker_info" | head -1 | awk '{print $1}')
        container_name=$(echo "$docker_info" | head -1 | awk '{print $2}')
        local status=$(echo "$docker_info" | head -1 | awk '{print $3}')
        
        if echo "$status" | grep -qi "up"; then
            running=1
            
            # Redis PING
            if docker exec "$container_name" redis-cli ping 2>/dev/null | grep -q "PONG"; then
                accessible=1
            fi
        fi
    fi
    
    # Kiểm tra Redis trên host
    if [[ $found -eq 0 ]] && pgrep -x redis-server &>/dev/null; then
        found=1
        running=1
        container_name="host"
        container_image="redis-host"
        if redis-cli ping 2>/dev/null | grep -q "PONG"; then
            accessible=1
        fi
    fi
    
    echo "# HELP db_redis_found 1 if Redis is found (Docker or host)"
    echo "# TYPE db_redis_found gauge"
    echo "db_redis_found{container=\"${container_name:-none}\",image=\"${container_image:-none}\"} ${found}"
    
    echo "# HELP db_redis_running 1 if Redis is running"
    echo "# TYPE db_redis_running gauge"
    echo "db_redis_running{container=\"${container_name:-none}\"} ${running}"
    
    echo "# HELP db_redis_accessible 1 if Redis is accepting connections"
    echo "# TYPE db_redis_accessible gauge"
    echo "db_redis_accessible{container=\"${container_name:-none}\"} ${accessible}"
}

# ==============================================================================
# MAIN
# ==============================================================================
{
    check_mysql
    check_postgresql
    check_redis
    
    # Metadata
    echo "# HELP db_status_scrape_timestamp Last scrape timestamp"
    echo "# TYPE db_status_scrape_timestamp gauge"
    echo "db_status_scrape_timestamp $(date +%s)"
    
    echo "# HELP db_status_scrape_success 1 if scrape succeeded"
    echo "# TYPE db_status_scrape_success gauge"
    echo "db_status_scrape_success 1"
    
} > "${TEMP_FILE}" 2>/dev/null || {
    {
        echo "# HELP db_status_scrape_success 1 if scrape succeeded"
        echo "# TYPE db_status_scrape_success gauge"
        echo "db_status_scrape_success 0"
    } > "${TEMP_FILE}"
}

mv "${TEMP_FILE}" "${OUTPUT_FILE}"
exit 0

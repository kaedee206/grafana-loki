#!/usr/bin/env bash
# ==============================================================================
# MONITORING STACK SETUP SCRIPT - setup.sh
# Tự động hóa toàn bộ quá trình cài đặt trên Fedora
# Chạy: sudo bash setup.sh
# ==============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${CYAN}========== $* ==========${NC}"; }

# ==============================================================================
# STEP 0: Kiểm tra prerequisites
# ==============================================================================
check_prerequisites() {
    log_section "Kiểm tra Prerequisites"
    
    local errors=0
    
    # Kiểm tra root
    if [[ $EUID -ne 0 ]]; then
        log_error "Script này cần chạy với quyền root (sudo bash setup.sh)"
        exit 1
    fi
    
    # Kiểm tra Docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker chưa được cài đặt!"
        log_info "Cài đặt Docker trên Fedora:"
        log_info "  sudo dnf install -y docker"
        log_info "  sudo systemctl enable --now docker"
        ((errors++))
    else
        local docker_version
        docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
        log_info "Docker: ${docker_version} ✓"
    fi
    
    # Kiểm tra Docker Compose
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null 2>&1; then
        log_error "Docker Compose chưa được cài đặt!"
        ((errors++))
    else
        log_info "Docker Compose ✓"
    fi
    
    # Kiểm tra certbot (nếu cần Let's Encrypt)
    if ! command -v certbot &>/dev/null; then
        log_warn "Certbot chưa cài. Nếu dùng Let's Encrypt:"
        log_warn "  sudo dnf install -y certbot"
        log_warn "  sudo certbot certonly --standalone -d your-domain.com"
    fi
    
    # Kiểm tra openssl
    if ! command -v openssl &>/dev/null; then
        log_error "openssl chưa cài đặt!"
        log_info "  sudo dnf install -y openssl"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Có ${errors} lỗi prerequisites. Vui lòng khắc phục trước khi tiếp tục."
        exit 1
    fi
    
    log_info "Tất cả prerequisites OK ✓"
}

# ==============================================================================
# STEP 1: Tạo file .env từ .env.example
# ==============================================================================
setup_env_file() {
    log_section "Cấu hình Environment Variables"
    
    if [[ -f "${BASE_DIR}/.env" ]]; then
        log_warn "File .env đã tồn tại. Bỏ qua bước này."
        log_warn "Xóa file .env nếu muốn reset: rm ${BASE_DIR}/.env"
        return
    fi
    
    cp "${BASE_DIR}/.env.example" "${BASE_DIR}/.env"
    
    # Sinh Grafana secret key ngẫu nhiên
    local secret_key
    secret_key=$(openssl rand -base64 32)
    sed -i "s|CHANGE_ME_RANDOM_SECRET_KEY_HERE|${secret_key}|g" "${BASE_DIR}/.env"
    
    # Nhắc admin password
    log_info "Nhập mật khẩu Grafana Admin (ít nhất 12 ký tự, phức tạp):"
    local grafana_pass
    while true; do
        read -rs -p "Grafana Admin Password: " grafana_pass
        echo ""
        if [[ ${#grafana_pass} -ge 12 ]]; then
            break
        fi
        log_warn "Mật khẩu phải ít nhất 12 ký tự!"
    done
    sed -i "s|CHANGE_ME_STRONG_PASSWORD_HERE|${grafana_pass}|g" "${BASE_DIR}/.env"
    
    # Nhập domain
    log_info "Nhập domain của server (ví dụ: monitor.example.com):"
    read -r domain
    sed -i "s|your-domain.com|${domain}|g" "${BASE_DIR}/.env"
    sed -i "s|your-domain.com|${domain}|g" "${BASE_DIR}/nginx/nginx.conf"
    sed -i "s|your-domain.com|${domain}|g" "${BASE_DIR}/grafana/grafana.ini"
    
    # Sinh Prometheus bcrypt hash
    if command -v htpasswd &>/dev/null; then
        local prom_hash
        prom_hash=$(htpasswd -nBC 10 "" | tr -d ':\n')
        sed -i "s|CHANGE_ME_BCRYPT_HASH_PLACEHOLDER_REPLACE_THIS|${prom_hash}|g" \
            "${BASE_DIR}/prometheus/web.yml"
        log_info "Prometheus bcrypt hash đã được tạo ✓"
    else
        log_warn "htpasswd không tìm thấy. Cài bằng: sudo dnf install -y httpd-tools"
        log_warn "Sau đó chạy: htpasswd -nBC 10 \"\" | tr -d ':\\n'"
        log_warn "Và điền vào prometheus/web.yml"
    fi
    
    # Set permissions cho .env
    chmod 600 "${BASE_DIR}/.env"
    log_info ".env file đã được tạo với permissions 600 ✓"
    log_warn "QUAN TRỌNG: Điền Telegram Bot Token, Discord Webhook, Email vào .env"
}

# ==============================================================================
# STEP 2: Tạo thư mục và set permissions
# ==============================================================================
setup_directories() {
    log_section "Tạo Thư mục và Set Permissions"
    
    # Tạo thư mục cần thiết
    local dirs=(
        "${BASE_DIR}/node_exporter_textfiles"
        "${BASE_DIR}/grafana/dashboards"
        "${BASE_DIR}/alertmanager/templates"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        log_info "Created: $dir"
    done
    
    # Set permissions đúng cho từng service
    # Prometheus (nobody: 65534)
    chown -R 65534:65534 "${BASE_DIR}/prometheus" 2>/dev/null || true
    
    # Grafana (grafana user: 472)
    chown -R 472:472 "${BASE_DIR}/grafana" 2>/dev/null || true
    
    # Textfiles directory (cần writable cho scripts, readable cho node-exporter)
    chmod 755 "${BASE_DIR}/node_exporter_textfiles"
    chown root:root "${BASE_DIR}/node_exporter_textfiles"
    
    # Scripts executable
    chmod +x "${SCRIPT_DIR}"/*.sh
    
    log_info "Permissions đã được set ✓"
}

# ==============================================================================
# STEP 3: Cài đặt cron jobs cho custom scripts
# ==============================================================================
setup_cron_jobs() {
    log_section "Cài đặt Cron Jobs"
    
    local cron_file="/etc/cron.d/monitoring-collectors"
    
    cat > "$cron_file" << CRON_CONTENT
# Monitoring Textfile Collectors
# Thu thập user sessions mỗi phút
* * * * * root OUTPUT_DIR=${BASE_DIR}/node_exporter_textfiles ${SCRIPT_DIR}/user_sessions.sh >> /var/log/user_sessions_collector.log 2>&1

# Thu thập DB status mỗi phút
* * * * * root OUTPUT_DIR=${BASE_DIR}/node_exporter_textfiles ${SCRIPT_DIR}/db_status.sh >> /var/log/db_status_collector.log 2>&1
CRON_CONTENT
    
    chmod 644 "$cron_file"
    log_info "Cron jobs đã được cài đặt tại ${cron_file} ✓"
    
    # Chạy scripts lần đầu để có metrics ngay
    log_info "Chạy collectors lần đầu..."
    OUTPUT_DIR="${BASE_DIR}/node_exporter_textfiles" bash "${SCRIPT_DIR}/user_sessions.sh" || true
    OUTPUT_DIR="${BASE_DIR}/node_exporter_textfiles" bash "${SCRIPT_DIR}/db_status.sh" || true
    log_info "Initial collection done ✓"
}

# ==============================================================================
# STEP 4: Cấu hình Firewall (firewalld trên Fedora)
# ==============================================================================
setup_firewall() {
    log_section "Cấu hình Firewall"
    
    if ! systemctl is-active --quiet firewalld; then
        log_warn "firewalld không chạy. Bỏ qua bước firewall."
        return
    fi
    
    # Chỉ cho phép port 80 và 443
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    
    # Đảm bảo các port exporter KHÔNG được mở
    for port in 9090 9100 8080 3100 9093; do
        firewall-cmd --permanent --remove-port="${port}/tcp" 2>/dev/null || true
    done
    
    # Reload firewall
    firewall-cmd --reload
    
    log_info "Firewall đã được cấu hình: chỉ port 80, 443 được mở ✓"
    log_info "Ports 9090/9100/8080/3100/9093 đã bị block ✓"
}

# ==============================================================================
# STEP 5: SSL Certificate với Let's Encrypt
# ==============================================================================
setup_ssl() {
    log_section "Cấu hình SSL Certificate"
    
    if [[ -f "${BASE_DIR}/.env" ]]; then
        # Extract domain from .env
        local domain
        domain=$(grep "GRAFANA_ROOT_URL" "${BASE_DIR}/.env" | sed 's|.*https://||' | tr -d '"\n')
        
        if [[ -z "$domain" || "$domain" == "your-domain.com" ]]; then
            log_warn "Domain chưa được cấu hình. Bỏ qua SSL."
            return
        fi
        
        if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
            log_info "SSL cert đã tồn tại cho ${domain} ✓"
            return
        fi
        
        log_info "Lấy SSL certificate cho ${domain}..."
        log_warn "Đảm bảo domain đã trỏ về IP server này và port 80 đang mở!"
        
        if command -v certbot &>/dev/null; then
            certbot certonly --standalone \
                -d "$domain" \
                --non-interactive \
                --agree-tos \
                --email "admin@${domain}" || {
                log_error "Certbot thất bại. Kiểm tra DNS và port 80."
                log_warn "Có thể chạy thủ công: certbot certonly --standalone -d ${domain}"
            }
        else
            log_warn "Certbot chưa cài. Chạy:"
            log_warn "  sudo dnf install -y certbot"
            log_warn "  sudo certbot certonly --standalone -d ${domain}"
        fi
    fi
    
    # Thêm cron cho auto-renewal
    echo "0 0,12 * * * root certbot renew --quiet --post-hook 'docker compose -f ${BASE_DIR}/docker-compose.yml restart nginx'" \
        > /etc/cron.d/certbot-renewal
    log_info "Certbot auto-renewal cron đã được cài ✓"
}

# ==============================================================================
# STEP 6: Khởi động Stack
# ==============================================================================
start_stack() {
    log_section "Khởi động Monitoring Stack"
    
    cd "${BASE_DIR}"
    
    # Pull images mới nhất
    log_info "Pulling Docker images..."
    docker compose pull
    
    # Start stack
    log_info "Khởi động services..."
    docker compose up -d
    
    log_info "Chờ services healthy..."
    sleep 15
    
    # Kiểm tra trạng thái
    docker compose ps
}

# ==============================================================================
# STEP 7: Verification
# ==============================================================================
verify_setup() {
    log_section "Kiểm tra Bảo mật và Hoạt động"
    
    local pass=0
    local fail=0
    
    check() {
        local name="$1"
        local cmd="$2"
        if eval "$cmd" &>/dev/null; then
            log_info "✓ ${name}"
            ((pass++))
        else
            log_warn "✗ ${name}"
            ((fail++))
        fi
    }
    
    # Kiểm tra containers đang chạy
    check "Grafana running" "docker ps | grep monitoring_grafana | grep Up"
    check "Prometheus running" "docker ps | grep monitoring_prometheus | grep Up"
    check "Loki running" "docker ps | grep monitoring_loki | grep Up"
    check "Node Exporter running" "docker ps | grep monitoring_node_exporter | grep Up"
    check "cAdvisor running" "docker ps | grep monitoring_cadvisor | grep Up"
    
    # SECURITY CHECKS
    log_section "Security Checks"
    
    # Kiểm tra các port exporter KHÔNG bị expose ra host
    check "Port 9090 NOT exposed" "! ss -tlnp | grep -E ':9090' | grep -v '127.0.0.1'"
    check "Port 9100 NOT exposed" "! ss -tlnp | grep -E ':9100' | grep -v '127.0.0.1'"
    check "Port 8080 NOT exposed" "! ss -tlnp | grep -E ':8080' | grep -v '127.0.0.1'"
    check "Port 3100 NOT exposed" "! ss -tlnp | grep -E ':3100' | grep -v '127.0.0.1'"
    
    # Kiểm tra Grafana auth
    check "Grafana requires auth" \
        "curl -sk https://localhost/ 2>/dev/null | grep -q 'login'"
    
    # Kiểm tra textfile collectors
    check "User sessions metrics exists" \
        "test -f ${BASE_DIR}/node_exporter_textfiles/user_sessions.prom"
    check "DB status metrics exists" \
        "test -f ${BASE_DIR}/node_exporter_textfiles/db_status.prom"
    
    echo ""
    log_info "Kết quả: ${pass} pass, ${fail} warnings"
    
    if [[ $fail -gt 0 ]]; then
        log_warn "Một số kiểm tra chưa pass. Kiểm tra lại cấu hình."
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║    DevSecOps Monitoring Stack - Auto Setup            ║"
    echo "║    Fedora Server | Security-First | Docker Compose    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_prerequisites
    setup_env_file
    setup_directories
    setup_cron_jobs
    setup_firewall
    setup_ssl
    start_stack
    verify_setup
    
    log_section "Hoàn thành!"
    log_info "Monitoring Stack đã được triển khai."
    log_info "Truy cập Grafana: https://\$(grep GRAFANA_ROOT_URL ${BASE_DIR}/.env | cut -d= -f2)"
    log_info ""
    log_warn "BƯỚC TIẾP THEO:"
    log_warn "1. Điền Telegram Bot Token, Discord Webhook URL, Email vào .env"
    log_warn "2. Restart alertmanager: docker compose restart alertmanager"
    log_warn "3. Import Grafana Dashboard ID: 1860 (Node Exporter Full)"
    log_warn "4. Import Grafana Dashboard ID: 193 (Docker Dashboard)"
    log_warn "5. Tạo dashboard tùy chỉnh cho DB status và User Sessions"
}

main "$@"

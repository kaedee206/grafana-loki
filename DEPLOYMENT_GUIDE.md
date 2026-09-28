# 🛡️ DevSecOps Monitoring Stack - Hướng Dẫn Triển Khai

> **Môi trường**: Fedora Server | Docker Compose | Security-First
> **Nguyên tắc**: Least Privilege, Zero Trust, Encrypt Everything

---

## 📁 Cấu trúc File đã tạo

```
~/monitoring/
├── docker-compose.yml          # Orchestration chính
├── .env.example                # Template secrets
├── .gitignore                  # Bảo vệ .env khỏi git
│
├── nginx/
│   └── nginx.conf              # Reverse Proxy + SSL + Rate Limiting
│
├── prometheus/
│   ├── prometheus.yml          # Scrape configs
│   ├── web.yml                 # TLS + Basic Auth
│   └── rules/
│       ├── alert.rules.yml     # Alerting rules (CPU/RAM/Disk/Container)
│       └── recording.rules.yml # Pre-computed metrics
│
├── alertmanager/
│   └── alertmanager.yml        # Telegram + Discord + Email routing
│
├── loki/
│   └── loki-config.yml         # Log aggregation
│
├── promtail/
│   └── promtail-config.yml     # Docker log collection
│
├── grafana/
│   ├── grafana.ini             # Security hardened config
│   └── provisioning/
│       ├── datasources/datasources.yml    # Auto Prometheus + Loki
│       ├── dashboards/dashboards.yml      # Dashboard provider
│       └── alerting/contact_points.yml   # Telegram/Discord/Email
│
└── scripts/
    ├── user_sessions.sh        # 🔑 Custom: SSH/Desktop/RDP metrics
    ├── db_status.sh            # 🔑 Custom: MySQL/PostgreSQL/Redis detection
    └── setup.sh                # 🔑 One-click automated setup
```

---

## 🚀 TRIỂN KHAI: Từng Bước Chi Tiết

### BƯỚC 0: Chuẩn bị Server Fedora

```bash
# Cập nhật hệ thống
sudo dnf update -y

# Cài đặt dependencies
sudo dnf install -y docker docker-compose openssl httpd-tools certbot cronie

# Khởi động Docker
sudo systemctl enable --now docker

# Thêm user vào group docker (không cần sudo mỗi lần)
sudo usermod -aG docker $USER
newgrp docker

# Bật crond để chạy cron jobs cho collectors
sudo systemctl enable --now crond
```

### BƯỚC 1: Lấy SSL Certificate (Let's Encrypt)

> [!IMPORTANT]
> Bước này cần domain đã trỏ về IP server và port 80 tạm thời mở.

```bash
# Cài certbot
sudo dnf install -y certbot

# Mở port 80 tạm thời để verify domain
sudo firewall-cmd --add-service=http

# Lấy certificate
sudo certbot certonly --standalone -d your-domain.com

# Xác nhận cert đã có
ls /etc/letsencrypt/live/your-domain.com/
# → fullchain.pem  privkey.pem  chain.pem  cert.pem
```

### BƯỚC 2: Cấu hình Secrets (.env)

```bash
cd ~/monitoring

# Copy từ template
cp .env.example .env

# Set permissions nghiêm ngặt (chỉ owner đọc được)
chmod 600 .env

# Sinh Grafana secret key ngẫu nhiên
SECRET_KEY=$(openssl rand -base64 32)
sed -i "s|CHANGE_ME_RANDOM_SECRET_KEY_HERE|${SECRET_KEY}|g" .env

# Sinh mật khẩu Grafana mạnh (ít nhất 16 ký tự)
GRAFANA_PASS=$(openssl rand -base64 16)
echo "Grafana Admin Password: ${GRAFANA_PASS}"
sed -i "s|CHANGE_ME_STRONG_PASSWORD_HERE|${GRAFANA_PASS}|g" .env

# Cập nhật domain
sed -i "s|your-domain.com|your-actual-domain.com|g" .env
sed -i "s|your-domain.com|your-actual-domain.com|g" nginx/nginx.conf
sed -i "s|your-domain.com|your-actual-domain.com|g" grafana/grafana.ini

# Điền Telegram Bot Token và Chat ID
nano .env
```

**Nội dung `.env` cần điền đầy đủ:**

```env
# Grafana
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<mật_khẩu_mạnh_16_ký_tự>
GRAFANA_SECRET_KEY=<random_base64_32>
GRAFANA_ROOT_URL=https://your-domain.com

# Telegram (tạo bot: https://t.me/BotFather)
TELEGRAM_BOT_TOKEN=1234567890:AABBCCDDEEFFaabbccddeeff
TELEGRAM_CHAT_ID=-1001234567890

# Discord (Server Settings → Integrations → Webhooks)
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...

# Email
SMTP_ENABLED=true
SMTP_HOST=smtp.gmail.com:587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-app-password
ALERTMANAGER_EMAIL_TO=admin@your-domain.com
```

### BƯỚC 3: Sinh Prometheus Basic Auth Hash

```bash
# Cài htpasswd nếu chưa có
sudo dnf install -y httpd-tools

# Sinh bcrypt hash (sẽ hỏi mật khẩu)
PROM_HASH=$(htpasswd -nBC 10 "" | tr -d ':\n')
echo "Hash: $PROM_HASH"

# Cập nhật vào web.yml
sed -i "s|CHANGE_ME_BCRYPT_HASH_PLACEHOLDER_REPLACE_THIS|${PROM_HASH}|g" \
    prometheus/web.yml
```

### BƯỚC 4: Cấu hình Firewall (Fedora firewalld)

```bash
# Đảm bảo chỉ port 80, 443 được mở
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https

# BLOCK tất cả ports của monitoring services
for port in 9090 9100 8080 3100 9093 3000; do
    sudo firewall-cmd --permanent --remove-port="${port}/tcp" 2>/dev/null || true
done

# Reload
sudo firewall-cmd --reload

# Xác nhận
sudo firewall-cmd --list-all
```

### BƯỚC 5: Cài đặt Cron Jobs (Custom Collectors)

```bash
# Tạo cron jobs cho custom metric collectors
sudo tee /etc/cron.d/monitoring-collectors << 'EOF'
# Thu thập user sessions (SSH/Desktop/RDP) mỗi phút
* * * * * root OUTPUT_DIR=/home/kaedee/monitoring/node_exporter_textfiles \
    /home/kaedee/monitoring/scripts/user_sessions.sh >> /var/log/user_sessions_collector.log 2>&1

# Thu thập DB status mỗi phút
* * * * * root OUTPUT_DIR=/home/kaedee/monitoring/node_exporter_textfiles \
    /home/kaedee/monitoring/scripts/db_status.sh >> /var/log/db_status_collector.log 2>&1
EOF

sudo chmod 644 /etc/cron.d/monitoring-collectors

# Chạy lần đầu ngay
sudo OUTPUT_DIR=/home/kaedee/monitoring/node_exporter_textfiles \
    bash /home/kaedee/monitoring/scripts/user_sessions.sh

sudo OUTPUT_DIR=/home/kaedee/monitoring/node_exporter_textfiles \
    bash /home/kaedee/monitoring/scripts/db_status.sh

# Kiểm tra output
cat node_exporter_textfiles/user_sessions.prom
cat node_exporter_textfiles/db_status.prom
```

### BƯỚC 6: Set Permissions Đúng

```bash
cd ~/monitoring

# Tạo thư mục dashboard nếu chưa có
mkdir -p grafana/dashboards alertmanager/templates

# Prometheus chạy với user nobody (65534)
sudo chown -R 65534:65534 prometheus/

# Grafana chạy với user 472
sudo chown -R 472:472 grafana/

# Loki chạy với user 10001
sudo chown -R 10001:10001 loki/

# Node exporter textfiles: writable bởi root (cron), readable bởi anyone
chmod 755 node_exporter_textfiles/
chmod +x scripts/*.sh
```

### BƯỚC 7: Khởi động Stack

```bash
cd ~/monitoring

# Pull tất cả images
docker compose pull

# Khởi động stack
docker compose up -d

# Theo dõi logs khởi động
docker compose logs -f --tail=50
```

**Thứ tự khởi động**: Loki → Prometheus → Alertmanager → Grafana → Nginx

---

## ✅ SECURITY CHECKLIST - Kiểm tra Sau Khi Deploy

### 1. Kiểm tra Port Exposure (Quan trọng nhất!)

```bash
# Chỉ port 80 và 443 được lắng nghe trên 0.0.0.0
# Tất cả ports khác phải KHÔNG xuất hiện hoặc chỉ trên 127.0.0.1
ss -tlnp | grep -E '9090|9100|8080|3100|9093|3000'
# Kết quả mong muốn: KHÔNG có output (hoặc chỉ 127.0.0.1)

# Kiểm tra từ ngoài (thay IP_SERVER bằng IP thật)
nmap -p 9090,9100,8080,3100,9093,3000 IP_SERVER
# Kết quả mong muốn: tất cả ports = filtered/closed
```

### 2. Kiểm tra Container Security

```bash
# Kiểm tra containers KHÔNG chạy root (trừ trường hợp cần thiết)
docker ps --format '{{.Names}}' | while read name; do
    user=$(docker inspect "$name" --format '{{.Config.User}}')
    echo "$name: user=${user:-root(default)}"
done

# Kiểm tra no-new-privileges
docker inspect monitoring_prometheus \
    --format '{{.HostConfig.SecurityOpt}}'
# Mong muốn: [no-new-privileges:true]
```

### 3. Kiểm tra Grafana Auth

```bash
# Grafana phải yêu cầu đăng nhập
curl -s https://your-domain.com/api/health
# Mong muốn: {"commit":"...","database":"ok","version":"..."}

# Anonymous access phải bị chặn
curl -s https://your-domain.com/api/dashboards/home
# Mong muốn: {"message":"Unauthorized"} hoặc redirect login
```

### 4. Kiểm tra TLS

```bash
# Kiểm tra SSL/TLS grade
# Chạy trên browser: https://www.ssllabs.com/ssltest/analyze.html?d=your-domain.com
# Hoặc dùng testssl.sh:
docker run --rm drwetter/testssl.sh your-domain.com
```

### 5. Kiểm tra Metrics Custom

```bash
# User sessions metric
curl -s http://localhost:9100/metrics | grep node_logged_users
# Mong muốn: thấy node_logged_users_total, node_logged_users_ssh, etc.

# DB status metric
curl -s http://localhost:9100/metrics | grep db_
# Mong muốn: thấy db_mysql_found, db_postgresql_found, db_redis_found
```

---

## 📊 GRAFANA: Cấu hình Dashboard

### Import Dashboard Có sẵn

1. Vào **Grafana** → **Dashboards** → **Import**
2. Nhập Dashboard ID:

| Dashboard ID | Mô tả |
|---|---|
| **1860** | Node Exporter Full (CPU, RAM, Disk, Network, Uptime) |
| **193** | Docker Container & Host Metrics (cAdvisor) |
| **13639** | Loki Dashboard |
| **15141** | Container-Level Log Monitoring |

### PromQL Queries cho Custom Metrics

**Panel: User Sessions Overview**
```promql
# Tổng users online
node_logged_users_total

# SSH sessions
node_logged_users_ssh_total

# Desktop sessions
node_logged_users_desktop_total

# RDP sessions
node_logged_users_rdp_total
```

**Panel: Database Status**
```promql
# MySQL status (1=running, 0=stopped/not found)
db_mysql_running

# PostgreSQL status
db_postgresql_running

# Redis status
db_redis_running

# Kết hợp: hiển thị N/A nếu không tìm thấy
db_mysql_found == 0
```

**Panel: Container Status Table**
```promql
# Containers đang chạy (cAdvisor)
count(container_last_seen{container!=""} > time()-120) by (name)

# Port mappings (cần dùng label từ Docker)
container_spec_cpu_quota{container!=""}
```

**Panel: Network Bandwidth**
```promql
# Download rate (bytes/s → Mbps)
rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m]) * 8 / 1024 / 1024

# Upload rate
rate(node_network_transmit_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m]) * 8 / 1024 / 1024
```

**Panel: /home Disk Usage**
```promql
(1 - (
  node_filesystem_avail_bytes{mountpoint="/home"}
  /
  node_filesystem_size_bytes{mountpoint="/home"}
)) * 100
```

**Panel: System Uptime**
```promql
node_time_seconds - node_boot_time_seconds
```

### Cấu hình Alert Contact Points (Grafana UI)

1. **Grafana** → **Alerting** → **Contact Points**
2. Contact points đã được pre-configured qua `provisioning/alerting/contact_points.yml`
3. Vào **Alerting** → **Notification Policies** để kiểm tra routing

### Test Alert

```bash
# Giả lập CPU cao để test alert (chạy trong 3 phút)
stress-ng --cpu $(nproc) --timeout 180s

# Hoặc test trực tiếp qua Alertmanager API
curl -X POST http://localhost:9093/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "warning"
    },
    "annotations": {
      "summary": "Test cảnh báo",
      "description": "Đây là test alert"
    }
  }]'
```

---

## 🔍 KIỂM TRA LOG QUA LOKI

### Xem Log Container trong Grafana

1. **Grafana** → **Explore** → Chọn datasource **Loki**
2. Dùng LogQL query:

```logql
# Log của container cụ thể
{container="ten_container_cua_ban"}

# Log có chứa "error"
{job="docker"} |= "error" | json

# Log 30 phút gần đây của tất cả containers
{job="docker"} | json | line_format "{{.container}}: {{.output}}"
```

---

## 🔧 QUẢN LÝ STACK

```bash
cd ~/monitoring

# Xem trạng thái tất cả services
docker compose ps

# Xem logs service cụ thể
docker compose logs -f grafana
docker compose logs -f prometheus
docker compose logs -f loki

# Restart service khi thay đổi config
docker compose restart prometheus
docker compose restart alertmanager

# Reload Prometheus config (không cần restart)
curl -X POST http://localhost:9090/-/reload

# Update stack (pull images mới)
docker compose pull && docker compose up -d

# Dừng toàn bộ stack
docker compose down

# Dừng VÀ xóa volumes (mất data!)
docker compose down -v
```

---

## 🔄 AUTO-RENEWAL SSL

```bash
# Certbot auto-renewal đã được setup. Kiểm tra:
cat /etc/cron.d/certbot-renewal

# Test renewal (dry run)
sudo certbot renew --dry-run

# Manual renewal nếu cần
sudo certbot renew
docker compose restart nginx
```

---

## ⚠️ TROUBLESHOOTING

### Grafana không load
```bash
docker compose logs grafana | tail -20
# Check: config file permissions, volume mounts
```

### Prometheus không scrape được
```bash
# Kiểm tra connectivity nội bộ
docker exec monitoring_prometheus \
    wget -q -O- http://node-exporter:9100/metrics | head -5
```

### Loki không nhận logs
```bash
docker compose logs promtail | tail -20
# Check: docker.sock permissions, container đang chạy
```

### Alert không gửi được Telegram
```bash
# Test bot token
curl "https://api.telegram.org/bot<TOKEN>/getMe"

# Test send message
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
    -d "chat_id=<CHAT_ID>&text=Test message"
```

---

## 📋 TỔNG KẾT SECURITY CHECKLIST

| Hạng mục | Trạng thái | Ghi chú |
|---|---|---|
| Port 9090/9100/8080/3100 không expose | ✅ | Chỉ trong Docker network |
| Chỉ port 80/443 mở ra internet | ✅ | Nginx gateway duy nhất |
| TLS 1.2/1.3 only | ✅ | nginx.conf |
| HSTS Header | ✅ | max-age=31536000 |
| Security Headers (X-Frame, CSP, etc.) | ✅ | nginx.conf |
| Rate Limiting (brute force) | ✅ | 5 req/s login, 20 req/s general |
| Grafana allow_sign_up = false | ✅ | grafana.ini |
| Grafana anonymous auth = false | ✅ | grafana.ini |
| Admin password via env variable | ✅ | Không hardcode |
| Secrets trong .env (chmod 600) | ✅ | Gitignored |
| Non-root containers | ✅ | 65534/472/10001 |
| no-new-privileges | ✅ | Tất cả containers |
| cap_drop ALL | ✅ | Chỉ thêm capabilities cần thiết |
| read-only filesystems | ✅ | Nơi có thể |
| Resource limits (CPU/Memory) | ✅ | deploy.resources |
| Loki retention 30 ngày | ✅ | Tránh disk đầy |
| Prometheus retention 30 ngày | ✅ | 10GB max |
| .gitignore cho .env và SSL | ✅ | .gitignore |
| Grafana analytics disabled | ✅ | Không gửi data về Grafana Labs |

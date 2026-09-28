 #!/usr/bin/env bash
# ==============================================================================
# USER SESSIONS TEXTFILE COLLECTOR - user_sessions.sh
# Thu thập thông tin người dùng đang online qua Prometheus Textfile Collector
#
# Metrics xuất ra:
#   - node_logged_users_total: Tổng số user đang online
#   - node_logged_users_ssh{user="...",remote_ip="..."}: SSH sessions
#   - node_logged_users_desktop{user="...",display="..."}: Desktop/X11 sessions
#   - node_logged_users_rdp{user="..."}: RDP sessions (xrdp)
#   - node_logged_users_wayland{user="..."}: Wayland sessions
#
# Cài đặt: Chạy qua cron mỗi 60 giây
#   * * * * * /opt/monitoring/scripts/user_sessions.sh
#
# Output directory: /opt/monitoring/node_exporter_textfiles/
# ==============================================================================

set -euo pipefail

# Thư mục output cho Node Exporter Textfile Collector
OUTPUT_DIR="${OUTPUT_DIR:-/home/kaedee/monitoring/node_exporter_textfiles}"
OUTPUT_FILE="${OUTPUT_DIR}/user_sessions.prom"
TEMP_FILE="${OUTPUT_FILE}.tmp.$$"

# Đảm bảo thư mục tồn tại
mkdir -p "${OUTPUT_DIR}"

# Dọn dẹp temp file khi script kết thúc hoặc bị interrupt
trap 'rm -f "${TEMP_FILE}"' EXIT

# ==============================================================================
# FUNCTIONS
# ==============================================================================

# Ghi metric với help và type
write_metric_header() {
    local name="$1"
    local help="$2"
    local type="$3"
    echo "# HELP ${name} ${help}"
    echo "# TYPE ${name} ${type}"
}

# Lấy SSH sessions
get_ssh_sessions() {
    local count=0
    local metric_lines=""
    
    # Đọc từ 'who' command - mỗi SSH session có dạng: user pts/N ip
    while IFS= read -r line; do
        local user tty date time remote
        user=$(echo "$line" | awk '{print $1}')
        tty=$(echo "$line" | awk '{print $2}')
        remote=$(echo "$line" | awk '{print $NF}' | tr -d '()')
        
        # Bỏ qua nếu không có IP/host (local console)
        if [[ -z "$remote" || "$remote" == ":" ]]; then
            continue
        fi
        
        # SSH sessions thường trên pts/* với remote IP
        if [[ "$tty" == pts/* ]]; then
            # Validate IP format hoặc hostname
            if [[ "$remote" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
               [[ "$remote" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                # Sanitize labels (loại bỏ ký tự không hợp lệ)
                local safe_user="${user//[^a-zA-Z0-9_]/_}"
                local safe_ip="${remote//[^a-zA-Z0-9._-]/_}"
                metric_lines="${metric_lines}node_logged_users_ssh{user=\"${safe_user}\",remote_ip=\"${safe_ip}\",tty=\"${tty}\"} 1\n"
                ((count++))
            fi
        fi
    done < <(who 2>/dev/null || true)
    
    write_metric_header "node_logged_users_ssh" "Number of active SSH sessions" "gauge"
    if [[ $count -gt 0 ]]; then
        echo -e "$metric_lines"
    fi
    echo "$count"  # Return count
}

# Lấy Desktop/X11 sessions
get_desktop_sessions() {
    local count=0
    local metric_lines=""
    
    # Kiểm tra X11 sessions
    while IFS= read -r line; do
        local user tty
        user=$(echo "$line" | awk '{print $1}')
        tty=$(echo "$line" | awk '{print $2}')
        
        # Desktop sessions trên tty* (không có remote IP)
        if [[ "$tty" == tty* ]]; then
            local safe_user="${user//[^a-zA-Z0-9_]/_}"
            local safe_tty="${tty//[^a-zA-Z0-9_]/_}"
            metric_lines="${metric_lines}node_logged_users_desktop{user=\"${safe_user}\",session_type=\"x11\",tty=\"${safe_tty}\"} 1\n"
            ((count++))
        fi
    done < <(who 2>/dev/null || true)
    
    # Kiểm tra GNOME/KDE/XFCE Wayland sessions qua loginctl
    if command -v loginctl &>/dev/null; then
        while IFS= read -r line; do
            local session_id user seat
            session_id=$(echo "$line" | awk '{print $1}')
            user=$(echo "$line" | awk '{print $3}')
            
            # Bỏ qua header
            [[ "$session_id" == "SESSION" ]] && continue
            [[ -z "$session_id" ]] && continue
            
            # Lấy chi tiết session
            local session_type seat
            session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || echo "unknown")
            seat=$(loginctl show-session "$session_id" -p Seat --value 2>/dev/null || echo "")
            
            if [[ "$session_type" == "wayland" || "$session_type" == "x11" ]]; then
                local safe_user="${user//[^a-zA-Z0-9_]/_}"
                local display_server="${session_type}"
                
                # Tránh đếm trùng với X11 từ 'who'
                if [[ "$session_type" == "wayland" ]]; then
                    metric_lines="${metric_lines}node_logged_users_desktop{user=\"${safe_user}\",session_type=\"wayland\",seat=\"${seat}\"} 1\n"
                    ((count++))
                fi
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    fi
    
    write_metric_header "node_logged_users_desktop" "Number of active desktop/GUI sessions" "gauge"
    if [[ $count -gt 0 ]]; then
        echo -e "$metric_lines"
    fi
    echo "$count"
}

# Lấy RDP sessions (nếu có xrdp)
get_rdp_sessions() {
    local count=0
    local metric_lines=""
    
    # Kiểm tra xrdp đang chạy
    if ! pgrep -x xrdp &>/dev/null && ! pgrep -x xrdp-sesman &>/dev/null; then
        write_metric_header "node_logged_users_rdp" "Number of active RDP sessions (xrdp)" "gauge"
        # Không có xrdp → RDP count = 0 (không phải N/A, chỉ là 0)
        echo "0"
        return
    fi
    
    # xrdp sessions thường tạo ra Xvnc processes
    while IFS= read -r line; do
        local user
        user=$(echo "$line" | awk '{print $1}')
        local safe_user="${user//[^a-zA-Z0-9_]/_}"
        metric_lines="${metric_lines}node_logged_users_rdp{user=\"${safe_user}\",protocol=\"rdp\"} 1\n"
        ((count++))
    done < <(ps aux | grep -E "Xvnc|xrdp-sesman" | grep -v grep | awk '{print $1}' | sort -u 2>/dev/null || true)
    
    write_metric_header "node_logged_users_rdp" "Number of active RDP sessions (xrdp)" "gauge"
    if [[ $count -gt 0 ]]; then
        echo -e "$metric_lines"
    fi
    echo "$count"
}

# ==============================================================================
# MAIN - Thu thập tất cả metrics và ghi ra file
# ==============================================================================

# Sử dụng subshell để capture metrics riêng biệt với count
{
    # ---- SSH Metrics ----
    ssh_count=0
    write_metric_header "node_logged_users_ssh" "Number of active SSH sessions" "gauge"
    while IFS= read -r line; do
        user=$(echo "$line" | awk '{print $1}')
        tty=$(echo "$line" | awk '{print $2}')
        remote=$(echo "$line" | awk '{print $NF}' | tr -d '()')
        
        [[ "$tty" != pts/* ]] && continue
        [[ -z "$remote" || "$remote" == ":" ]] && continue
        
        safe_user="${user//[^a-zA-Z0-9_]/_}"
        safe_ip="${remote//[^a-zA-Z0-9._:-]/_}"
        echo "node_logged_users_ssh{user=\"${safe_user}\",remote_ip=\"${safe_ip}\",tty=\"${tty//\//_}\"} 1"
        ((ssh_count++)) || true
    done < <(who 2>/dev/null || true)
    
    # ---- Desktop/X11 Metrics ----
    desktop_count=0
    write_metric_header "node_logged_users_desktop" "Number of active desktop/GUI sessions" "gauge"
    
    # X11 từ tty
    while IFS= read -r line; do
        user=$(echo "$line" | awk '{print $1}')
        tty=$(echo "$line" | awk '{print $2}')
        [[ "$tty" != tty* ]] && continue
        safe_user="${user//[^a-zA-Z0-9_]/_}"
        echo "node_logged_users_desktop{user=\"${safe_user}\",session_type=\"x11\",tty=\"${tty}\"} 1"
        ((desktop_count++)) || true
    done < <(who 2>/dev/null || true)
    
    # Wayland từ loginctl
    if command -v loginctl &>/dev/null; then
        while IFS= read -r session_line; do
            session_id=$(echo "$session_line" | awk '{print $1}')
            session_user=$(echo "$session_line" | awk '{print $3}')
            [[ "$session_id" == "SESSION" || -z "$session_id" ]] && continue
            
            s_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || echo "")
            s_seat=$(loginctl show-session "$session_id" -p Seat --value 2>/dev/null || echo "seat0")
            
            if [[ "$s_type" == "wayland" ]]; then
                safe_user="${session_user//[^a-zA-Z0-9_]/_}"
                echo "node_logged_users_desktop{user=\"${safe_user}\",session_type=\"wayland\",seat=\"${s_seat}\"} 1"
                ((desktop_count++)) || true
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    fi
    
    # ---- RDP Metrics ----
    rdp_count=0
    write_metric_header "node_logged_users_rdp" "Number of active RDP sessions (xrdp)" "gauge"
    if pgrep -x xrdp &>/dev/null || pgrep -x xrdp-sesman &>/dev/null; then
        while IFS= read -r rdp_user; do
            [[ -z "$rdp_user" ]] && continue
            safe_user="${rdp_user//[^a-zA-Z0-9_]/_}"
            echo "node_logged_users_rdp{user=\"${safe_user}\",protocol=\"rdp\"} 1"
            ((rdp_count++)) || true
        done < <(ps aux | grep -E "Xvnc|xrdp-sesman" | grep -v grep | awk '{print $1}' | sort -u 2>/dev/null || true)
    fi
    
    # ---- TOTAL SUMMARY ----
    total_count=$((ssh_count + desktop_count + rdp_count))
    
    write_metric_header "node_logged_users_total" "Total number of logged in users" "gauge"
    echo "node_logged_users_total ${total_count}"
    
    write_metric_header "node_logged_users_ssh_total" "Total number of SSH sessions" "gauge"
    echo "node_logged_users_ssh_total ${ssh_count}"
    
    write_metric_header "node_logged_users_desktop_total" "Total number of desktop/GUI sessions" "gauge"
    echo "node_logged_users_desktop_total ${desktop_count}"
    
    write_metric_header "node_logged_users_rdp_total" "Total number of RDP sessions" "gauge"
    echo "node_logged_users_rdp_total ${rdp_count}"
    
    # ---- SCRIPT METADATA ----
    write_metric_header "node_user_sessions_scrape_timestamp" "Last scrape timestamp" "gauge"
    echo "node_user_sessions_scrape_timestamp $(date +%s)"
    
    write_metric_header "node_user_sessions_scrape_success" "1 if scrape succeeded" "gauge"
    echo "node_user_sessions_scrape_success 1"
    
} > "${TEMP_FILE}" 2>/dev/null || {
    # Nếu có lỗi, ghi metric failure
    {
        write_metric_header "node_user_sessions_scrape_success" "1 if scrape succeeded" "gauge"
        echo "node_user_sessions_scrape_success 0"
    } > "${TEMP_FILE}"
}

# Atomic rename để tránh Node Exporter đọc file đang ghi
mv -f "${TEMP_FILE}" "${OUTPUT_FILE}"

exit 0

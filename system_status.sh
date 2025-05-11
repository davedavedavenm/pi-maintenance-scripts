#!/bin/bash
#
# Pi System Status Script (Enhanced Version)
# Provides weekly system status reports via HTML email
#

# --- Configuration ---
PI_CONFIG_FILE="$(dirname "$0")/pi_config.sh"
if [ -f "$PI_CONFIG_FILE" ]; then
    source "$PI_CONFIG_FILE"
fi

PI_EMAIL="${PI_EMAIL:-your-email@example.com}"
PI_USER_FOR_PATHS="${PI_USER_FOR_PATHS:-dave}" # User whose home dir contains relevant logs/configs if not root's
PI_HOME_FOR_PATHS="${PI_HOME_FOR_PATHS:-/home/$PI_USER_FOR_PATHS}"

# Determine effective user and home for script's own logs/configs if not overridden
EFFECTIVE_PI_USER="${PI_USER:-$(whoami)}" 
EFFECTIVE_PI_HOME="${PI_HOME:-$(eval echo ~$EFFECTIVE_PI_USER)}" 

PI_HOSTNAME="${PI_HOSTNAME:-$(hostname)}"
# Use dave's msmtprc by default, assuming root can read it or it's configured in pi_config.sh
PI_MSMTP_CONFIG="${PI_MSMTP_CONFIG:-${PI_HOME_FOR_PATHS}/.msmtprc}" 

LOG_DIR="${EFFECTIVE_PI_HOME}/logs" # This script's own operational log (e.g. /root/logs)
LOG_FILE="${LOG_DIR}/system_status_generation.log" 
MAX_LOG_ARCHIVES=3

EMAIL_TO="${PI_EMAIL}"
SUBJECT_PREFIX="${PI_HOSTNAME} Weekly Status Report" 

# Corrected paths for dependent logs
UPDATE_AND_RESTART_LOG="${PI_HOME_FOR_PATHS}/logs/update-and-restart.log" 
SD_BACKUP_LOG_PATTERN="${PI_HOME_FOR_PATHS}/${PI_HOSTNAME}_backup.log" 

# --- Error Handling & Setup ---
set -uo pipefail 
mkdir -p "$LOG_DIR" || { echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to create log directory $LOG_DIR. Exiting." >&2; exit 1; }

# --- Helper Functions (assumed to be correct from previous versions) ---
log_message() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] - $message" >> "$LOG_FILE"
}

initial_log_rotation() {
    if [ ! -f "$LOG_FILE" ]; then 
        touch "$LOG_FILE" || { log_message "ERROR" "Failed to touch log file $LOG_FILE"; exit 1; }
        return
    fi
    if [ -s "$LOG_FILE" ]; then 
      for i in $(seq $((MAX_LOG_ARCHIVES-1)) -1 1); do
        if [ -f "${LOG_FILE}.${i}.gz" ]; then
          mv "${LOG_FILE}.${i}.gz" "${LOG_FILE}.$((i+1)).gz"
        fi
      done
      gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz" 
      truncate -s 0 "$LOG_FILE" 
      echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] - Main log rotated to ${LOG_FILE}.1.gz" >> "$LOG_FILE"
    fi
}

get_cmd_output() {
    local cmd="$1"
    local output
    output=$($cmd 2>&1) 
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_message "WARNING" "Command failed (exit $exit_code): $cmd - Raw Output: $output"
        echo "Error executing command" 
    else
        echo "$output"
    fi
}

check_service_html() {
    local service_name="$1"
    local display_name="$2"
    local status_text
    local status_class
    local detail_info=""
    if systemctl is-active --quiet "$service_name"; then
        status_text="✅ Active"; status_class="status-ok"
    else
        status_text="❌ Inactive"; status_class="status-error"
        detail_info=$(systemctl status "$service_name" 2>&1 | grep -E 'Active:|Loaded:' | head -n 2 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | tr '\n' ' ')
        if [ -n "$detail_info" ]; then status_text+=" <small>($detail_info)</small>"; fi
        page_issues+=("Service $display_name is Inactive: $detail_info")
    fi
    echo "<tr><td>${display_name}</td><td><span class='${status_class}'>${status_text}</span></td></tr>"
}

generate_report_html() {
    local title="$1"; local overall_status_html="$2"; local sections_html_ref="$3" 
    declare -n sections_html_arr="$sections_html_ref"; local current_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local all_sections=""; for section in "${sections_html_arr[@]}"; do all_sections+="$section"; done
    cat <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font-family:Arial,sans-serif;margin:10px;background-color:#f4f4f4;color:#333}.container{max-width:700px;margin:20px auto;background-color:#fff;padding:20px;border-radius:8px;box-shadow:0 0 15px rgba(0,0,0,.1)}.header{background-color:#4a69bd;color:#fff;padding:15px;text-align:center;border-radius:8px 8px 0 0}.header h2{margin:0}.overall-status{padding:15px;margin:20px 0;border-radius:5px;font-size:1.1em;text-align:center}.status-ok-bg{background-color:#d4edda;color:#155724;border-left:6px solid #28a745}.status-warn-bg{background-color:#fff3cd;color:#856404;border-left:6px solid #ffc107}.status-error-bg{background-color:#f8d7da;color:#721c24;border-left:6px solid #dc3545}.section{margin-bottom:20px}.section h3{background-color:#e9ecef;color:#495057;padding:10px;margin-top:0;border-radius:4px;border-bottom:2px solid #ced4da}table{width:100%;border-collapse:collapse;margin-bottom:10px}th,td{border:1px solid #dee2e6;padding:8px;text-align:left;font-size:.9em}th{background-color:#f8f9fa}pre{white-space:pre-wrap;word-wrap:break-word;background-color:#f5f5f5;border:1px solid #ccc;padding:10px;max-height:200px;overflow-y:auto;border-radius:4px}.status-ok{color:green;font-weight:700}.status-error{color:red;font-weight:700}.status-warn{color:orange;font-weight:700}.footer{font-size:.85em;text-align:center;color:#6c757d;margin-top:25px;border-top:1px solid #eee;padding-top:15px}</style></head><body><div class="container"><div class="header"><h2>${title}</h2></div>${overall_status_html}${all_sections}<div class="footer"><p>Report generated on ${current_timestamp} by $(hostname)</p></div></div></body></html>
EOF
}

send_report_email() {
    local subject="$1"; local html_body="$2"
    if [ ! -f "$PI_MSMTP_CONFIG" ]; then log_message "ERROR" "msmtp config not found: $PI_MSMTP_CONFIG"; return 1; fi
    if command -v msmtp &>/dev/null; then
        printf "To:%s\nSubject:%s\nContent-Type:text/html;charset=utf-8\nMIME-Version:1.0\n\n%s" "$EMAIL_TO" "$subject" "$html_body" | msmtp --file="$PI_MSMTP_CONFIG" -a default "$EMAIL_TO"
        if [ $? -ne 0 ]; then log_message "ERROR" "msmtp send failed: $subject"; else log_message "INFO" "Email sent via msmtp: $subject"; fi
    elif command -v mail &>/dev/null; then
        printf "Subject:%s\nContent-Type:text/html;charset=utf-8\nMIME-Version:1.0\n\n%s" "$subject" "$html_body" | mail -s "$subject" "$EMAIL_TO"
        if [ $? -ne 0 ]; then log_message "ERROR" "mail send failed: $subject"; else log_message "INFO" "Email sent via mail: $subject"; fi
    else log_message "ERROR" "No mail client found"; fi
}

# --- Main Script ---
initial_log_rotation
log_message "INFO" "System status report generation started."
page_issues=() 

if [[ $EUID -ne 0 ]]; then 
   log_message "ERROR" "This script must be run as root for full data. Exiting."
   exit 1
fi

# --- Section: System Health ---
html_sys_health="<div class='section'><h3>📊 System Health</h3><table>"
disk_usage_root_full=$(get_cmd_output "df -h /")
disk_usage_root_main_line=$(echo "$disk_usage_root_full" | awk 'NR==2') 
disk_percent=$(echo "$disk_usage_root_main_line" | awk '{print $5}' | sed 's/%//')
disk_free=$(echo "$disk_usage_root_main_line" | awk '{print $4}')
disk_status_class="status-ok"
if [[ "$disk_percent" =~ ^[0-9]+$ ]]; then 
    if [ "$disk_percent" -gt 80 ] && [ "$disk_percent" -le 90 ]; then disk_status_class="status-warn"; page_issues+=("Disk usage at ${disk_percent}% (Warning)");
    elif [ "$disk_percent" -gt 90 ]; then disk_status_class="status-error"; page_issues+=("Disk usage at ${disk_percent}% (Critical)"); fi
    html_sys_health+="<tr><td>Disk Usage (/)</td><td><span class='${disk_status_class}'>${disk_percent}%</span> (Free: ${disk_free})</td></tr>"
else
    log_message "WARNING" "Could not parse disk usage percentage: '$disk_percent' from line: '$disk_usage_root_main_line'"
    html_sys_health+="<tr><td>Disk Usage (/)</td><td><span class='status-error'>Error parsing</span></td></tr>"; page_issues+=("Error parsing disk usage")
fi

mem_info_full=$(get_cmd_output "free -h")
mem_line=$(echo "$mem_info_full" | awk '/^Mem:/ {print $0}')
if [ -n "$mem_line" ]; then
    mem_total=$(echo "$mem_line" | awk '{print $2}'); mem_used=$(echo "$mem_line" | awk '{print $3}'); mem_available=$(echo "$mem_line" | awk '{print $7}')
    # Corrected FS to [A-Za-z]+ for proper float parsing by awk $1
    mem_used_mb=$(echo "$mem_used" | awk '/Gi/{val=$1*1024} /Mi/{val=$1} END{print val}' FS='[A-Za-z]+') 
    mem_total_mb=$(echo "$mem_total" | awk '/Gi/{val=$1*1024} /Mi/{val=$1} END{print val}' FS='[A-Za-z]+') 
    mem_status_class="status-ok"
    if [[ "$mem_total_mb" =~ ^[0-9]+(\.[0-9]+)?$ && "$mem_used_mb" =~ ^[0-9]+(\.[0-9]+)?$ && $(echo "$mem_total_mb > 0" | bc -l) -eq 1 ]]; then
        mem_used_percent=$(awk -v used="$mem_used_mb" -v total="$mem_total_mb" 'BEGIN { printf "%.0f", (used/total)*100 }')
        if [ "$mem_used_percent" -gt 85 ] && [ "$mem_used_percent" -le 95 ]; then mem_status_class="status-warn"; page_issues+=("Memory usage at ${mem_used_percent}% (Warning)");
        elif [ "$mem_used_percent" -gt 95 ]; then mem_status_class="status-error"; page_issues+=("Memory usage at ${mem_used_percent}% (Critical)"); fi
        html_sys_health+="<tr><td>Memory Usage</td><td><span class='${mem_status_class}'>${mem_used} / ${mem_total}</span> (Available: ${mem_available})</td></tr>"
    else
        log_message "WARNING" "Could not parse memory usage. Used_MB:'$mem_used_mb', Total_MB:'$mem_total_mb'"; html_sys_health+="<tr><td>Memory Usage</td><td><span class='status-error'>Error parsing</span></td></tr>"; page_issues+=("Error parsing memory usage")
    fi
else
    log_message "WARNING" "Could not get Mem: line from free -h: $mem_info_full"; html_sys_health+="<tr><td>Memory Usage</td><td><span class='status-error'>Error fetching</span></td></tr>"; page_issues+=("Error fetching memory usage")
fi

cpu_temp_text="N/A"; temp_raw=$(get_cmd_output "cat /sys/class/thermal/thermal_zone0/temp")
if [[ "$temp_raw" =~ ^[0-9]+$ ]]; then 
    cpu_temp=$(echo "scale=1; $temp_raw / 1000" | bc); temp_status_class="status-ok"
    if (( $(echo "$cpu_temp > 65" | bc -l) )); then temp_status_class="status-warn"; page_issues+=("CPU Temp at ${cpu_temp}°C (Warning)"); fi
    if (( $(echo "$cpu_temp > 75" | bc -l) )); then temp_status_class="status-error"; page_issues+=("CPU Temp at ${cpu_temp}°C (High)"); fi
    cpu_temp_text="<span class='${temp_status_class}'>${cpu_temp}°C</span>"
elif [[ "$temp_raw" == "Error executing command" ]]; then cpu_temp_text="<span class='status-error'>Error reading temp</span>"; page_issues+=("Error reading CPU temperature");
else log_message "WARNING" "Unexpected CPU temp value: $temp_raw"; cpu_temp_text="<span class='status-warn'>N/A</span>"; fi
html_sys_health+="<tr><td>CPU Temperature</td><td>${cpu_temp_text}</td></tr>"
html_sys_health+="<tr><td>System Uptime</td><td>$(get_cmd_output "uptime -p")</td></tr></table></div>"

# --- Section: Maintenance Status ---
html_maintenance="<div class='section'><h3>🔄 Maintenance Status</h3><table>"
backup_status_text="<span class='status-warn'>Log not found or no recent entry</span>"; add_backup_issue=true
# Using corrected SD_BACKUP_LOG_PATTERN which points to /home/dave/...
if [ -f "$SD_BACKUP_LOG_PATTERN" ]; then # Check specific file, not pattern with ls
    last_backup_line=$(grep -ai "Backup process finished\|Backup completed successfully" "$SD_BACKUP_LOG_PATTERN" | tail -1)
    if [ -n "$last_backup_line" ]; then
        backup_date=$(echo "$last_backup_line" | grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{4}|[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1); backup_time=$(echo "$last_backup_line" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1) 
        backup_status_text="<span class='status-ok'>✅ Last backup: ${backup_date} ${backup_time}</span>"; add_backup_issue=false
        if [[ -n "$backup_date" ]]; then
            backup_epoch=$(date -d "$backup_date $backup_time" +%s 2>/dev/null || date -d "$(echo $backup_date | awk -F'/' '{print $3"-"$2"-"$1}') $backup_time" +%s 2>/dev/null) 
            if [[ -n "$backup_epoch" ]] && [ $(( $(date +%s) - backup_epoch )) -gt $((8 * 24 * 60 * 60)) ]; then
                backup_status_text="<span class='status-warn'>⚠️ Last backup ${backup_date} ${backup_time} (Older than 7 days)</span>"; add_backup_issue=true; page_issues+=("Last backup is older than 7 days")
            fi; fi
    else backup_status_text="<span class='status-error'>❌ No success entry in backup log</span>"; add_backup_issue=true; fi
else backup_status_text="<span class='status-error'>❌ Backup log not found: $SD_BACKUP_LOG_PATTERN</span>"; add_backup_issue=true; fi
if $add_backup_issue; then page_issues+=("SD Card Backup: ${backup_status_text//<[^>]*/}"); fi # Add text only to issues
html_maintenance+="<tr><td>SD Card Backup</td><td>${backup_status_text}</td></tr>"

update_status_text="<span class='status-warn'>Log not found or no recent entry</span>"; add_update_issue=true
# Using corrected UPDATE_AND_RESTART_LOG which points to /home/dave/logs/...
if [ -f "$UPDATE_AND_RESTART_LOG" ]; then
    last_update_line=$(grep -ai "Update completed successfully" "$UPDATE_AND_RESTART_LOG" | tail -1)
     if [ -n "$last_update_line" ]; then
        update_date=$(echo "$last_update_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1); update_time=$(echo "$last_update_line" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1) 
        update_status_text="<span class='status-ok'>✅ Last update: ${update_date} ${update_time}</span>"; add_update_issue=false
        if [[ -n "$update_date" ]]; then
            update_epoch=$(date -d "$update_date $update_time" +%s)
             if [ $(( $(date +%s) - update_epoch )) -gt $((8 * 24 * 60 * 60)) ]; then 
                update_status_text="<span class='status-warn'>⚠️ Last update ${update_date} ${update_time} (Older than 7 days)</span>"; add_update_issue=true; page_issues+=("Last system update is older than 7 days")
            fi; fi
    else update_status_text="<span class='status-error'>❌ No success entry in update log</span>"; add_update_issue=true; fi
else update_status_text="<span class='status-error'>❌ Update log not found: $UPDATE_AND_RESTART_LOG</span>"; add_update_issue=true; fi
if $add_update_issue; then page_issues+=("System Updates: ${update_status_text//<[^>]*/}"); fi
html_maintenance+="<tr><td>System Updates</td><td>${update_status_text}</td></tr></table></div>"

# --- Section: Security Status ---
html_security="<div class='section'><h3>🛡️ Security Status</h3><table>"
failed_ssh_logins_text="<span class='status-warn'>N/A</span>" # Default
auth_log_path="/var/log/auth.log"
if [ -f "$auth_log_path" ]; then
    failed_ssh_logins_cmd_output=$(get_cmd_output "grep -ac 'Failed password' $auth_log_path")
    if [[ "$failed_ssh_logins_cmd_output" == "Error executing command" ]]; then failed_ssh_logins_text="<span class='status-error'>Error reading</span>"; page_issues+=("Error reading failed SSH logins from $auth_log_path");
    elif [[ "$failed_ssh_logins_cmd_output" =~ ^[0-9]+$ ]]; then failed_ssh_logins_text="$failed_ssh_logins_cmd_output";
    else log_message "WARNING" "Unexpected output for failed SSH: $failed_ssh_logins_cmd_output"; failed_ssh_logins_text="<span class='status-warn'>Parse Err</span>"; page_issues+=("Error parsing failed SSH login count"); fi
else failed_ssh_logins_text="<span class='status-ok'>Log not found</span>"; log_message "INFO" "$auth_log_path not found, cannot check failed SSH logins."; fi
html_security+="<tr><td>Failed SSH Logins (in $auth_log_path)</td><td>${failed_ssh_logins_text}</td></tr>"

banned_ips_text="N/A"
if command -v fail2ban-client &> /dev/null; then
    banned_ips_raw=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Total banned" | grep -oE "[0-9]+")
    if [[ "$banned_ips_raw" =~ ^[0-9]+$ ]]; then banned_ips_text="$banned_ips_raw";
    else banned_ips_text="<span class='status-warn'>Error/None</span>"; log_message "WARNING" "Could not parse banned IPs from fail2ban."; fi
else banned_ips_text="<span class='status-ok'>Not found</span>"; fi
html_security+="<tr><td>Currently Banned IPs (fail2ban sshd)</td><td>${banned_ips_text}</td></tr></table></div>"

# --- Section: Service Status ---
html_services="<div class='section'><h3>🚦 Service Status</h3><table>"
html_services+=$(check_service_html "ssh" "SSH Server")
if command -v pihole &> /dev/null; then html_services+=$(check_service_html "pihole-FTL" "Pi-hole FTL"); else html_services+="<tr><td>Pi-hole FTL</td><td><span class='status-ok'>Not installed</span></td></tr>"; fi
if systemctl list-unit-files --no-pager | grep -q cloudflared.service; then html_services+=$(check_service_html "cloudflared" "Cloudflared"); else html_services+="<tr><td>Cloudflared</td><td><span class='status-ok'>Not installed</span></td></tr>"; fi
if command -v docker &> /dev/null; then html_services+=$(check_service_html "docker" "Docker Service"); else html_services+="<tr><td>Docker Service</td><td><span class='status-ok'>Not installed</span></td></tr>"; fi
html_services+="</table></div>"

# --- Section: Docker Containers ---
html_docker=""
if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
    html_docker="<div class='section'><h3>🐳 Docker Containers</h3>"
    container_list_raw=$(get_cmd_output "docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'")
    if [[ "$container_list_raw" == "Error executing command" ]]; then html_docker+="<p>Error fetching container list.</p>"; page_issues+=("Error fetching Docker container list");
    elif [ -z "$container_list_raw" ]; then html_docker+="<p>No containers running.</p>";
    else
        html_docker+="<table><tr><th>Name</th><th>Image</th><th>Status</th></tr>"
        echo "$container_list_raw" | sed '/^\s*$/d' | while IFS= read -r line; do 
            name=$(echo "$line" | awk -F'\t' '{print $1}'); image=$(echo "$line" | awk -F'\t' '{print $2}'); status=$(echo "$line" | awk -F'\t' '{print $3}')
            status_html=$(echo "$status" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g') 
            if [[ "$status" != Up* ]]; then status_html="<span class='status-error'>${status_html}</span>"; page_issues+=("Docker container $name status: $status");
            else status_html="<span class='status-ok'>${status_html}</span>"; fi
            html_docker+="<tr><td>$name</td><td>$image</td><td>$status_html</td></tr>"; done 
        html_docker+="</table>"; fi; html_docker+="</div>"
fi

# --- Section: Pi-hole Stats ---
html_pihole=""
if command -v pihole &> /dev/null && systemctl is-active --quiet pihole-FTL; then
    html_pihole="<div class='section'><h3><img src='https://pi-hole.net/wp-content/uploads/2016/12/Vortex-R-WO-Words-NoBG-225x225.png' alt='Pi-hole' style='height:20px; vertical-align:middle;'> Pi-hole Stats (Today)</h3>"
    pihole_stats_json_raw=$(get_cmd_output "pihole -c -j")
    if [[ "$pihole_stats_json_raw" == "Error executing command" ]]; then html_pihole+="<p>Error fetching Pi-hole stats.</p>"; page_issues+=("Error fetching Pi-hole stats");
    else
        dns_queries="N/A"; ads_blocked="N/A"; percent_blocked="N/A" 
        if command -v jq &> /dev/null; then
            dns_queries=$(echo "$pihole_stats_json_raw" | jq -r .dns_queries_today // "\"N/A\""); ads_blocked=$(echo "$pihole_stats_json_raw" | jq -r .ads_blocked_today // "\"N/A\""); percent_blocked=$(echo "$pihole_stats_json_raw" | jq -r .ads_percentage_today // "\"N/A\"")
        else 
            dns_queries=$(echo "$pihole_stats_json_raw" | grep -oP '"dns_queries_today":\s*\K[0-9]+' || echo "N/A"); ads_blocked=$(echo "$pihole_stats_json_raw" | grep -oP '"ads_blocked_today":\s*\K[0-9]+' || echo "N/A"); percent_blocked=$(echo "$pihole_stats_json_raw" | grep -oP '"ads_percentage_today":\s*\K[0-9.]+' || echo "N/A"); fi
        html_pihole+="<table><tr><td>Total DNS Queries</td><td>${dns_queries}</td></tr><tr><td>Ads Blocked</td><td>${ads_blocked}</td></tr><tr><td>Percentage Blocked</td><td>${percent_blocked}%</td></tr></table>"; fi
    html_pihole+="</div>"
fi

# --- Assemble and Send Report ---
sections_array=("$html_sys_health" "$html_maintenance" "$html_security" "$html_services" "$html_docker" "$html_pihole")
overall_status_class="status-ok-bg"; overall_status_message="✅ System Status: All Clear"; report_subject_suffix="SUCCESS"
if [ ${#page_issues[@]} -gt 0 ]; then
    issue_summary="<ul>"; for issue in "${page_issues[@]}"; do issue_summary+="<li>$(echo "$issue" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</li>"; done; issue_summary+="</ul>"
    if printf '%s\n' "${page_issues[@]}" | grep -qE "Critical|High|Failed|Error|Inactive|No success entry"; then
        overall_status_class="status-error-bg"; overall_status_message="❌ System Status: Issues Found!"; report_subject_suffix="ISSUES DETECTED"
    else overall_status_class="status-warn-bg"; overall_status_message="⚠️ System Status: Warnings"; report_subject_suffix="WARNINGS"; fi
    sections_array+=("<div class='section'><h3>🚩 Detected Issues</h3>${issue_summary}</div>")
fi
overall_html="<div class='overall-status ${overall_status_class}'>${overall_status_message}</div>"
final_html_body=$(generate_report_html "$PI_HOSTNAME Status Report" "$overall_html" "sections_array") 
final_subject="${SUBJECT_PREFIX} - ${report_subject_suffix}"
send_report_email "$final_subject" "$final_html_body"
log_message "INFO" "System status report generation finished. Overall status: $report_subject_suffix"
find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*.gz" -type f -printf '%T@ %p\n' | sort -V -r | tail -n +${MAX_LOG_ARCHIVES} | cut -d' ' -f2- | xargs -r rm
exit 0

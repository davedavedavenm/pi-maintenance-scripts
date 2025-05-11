#!/bin/bash
# System Update and Restart Script (run as root)

# --- Configuration ---
LOG_DIR="/home/dave/logs" 
LOG_FILE="${LOG_DIR}/update-and-restart.log" 
MSMTP_CONFIG="/home/dave/.msmtprc" 
MSMTP_ACCOUNT="default"
RECIPIENT_EMAIL="david@davidmagnus.co.uk"
HOSTNAME_LABEL="KH Pi 3" 

DISK_WARN_THRESHOLD=90
MAX_RETRIES=3
RETRY_DELAY=5
MAX_LOG_FILES=5 # Total files to aim for (current log + MAX_LOG_FILES-1 archives)

# --- Error Handling & Setup ---
set -euo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR

mkdir -p "$LOG_DIR" || { echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to create log directory $LOG_DIR. Exiting." >&2; exit 1; }

# --- Helper Functions ---

log_message() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] - $message" >> "$LOG_FILE"
}

generate_email_html() {
    local title="$1"
    local status_class="$2"
    local status_message="$3"
    local details_html="$4"
    local current_timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    cat <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
    body { font-family: Arial, sans-serif; margin: 0; padding: 0; background-color: #f4f4f4; }
    .container { max-width: 600px; margin: 20px auto; background-color: #ffffff; padding: 20px; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
    .header { background-color: #007bff; color: white; padding: 10px 0; text-align: center; border-radius: 8px 8px 0 0; }
    .header h2 { margin: 0; }
    .status { padding: 15px; margin: 15px 0; border-radius: 4px; font-weight: bold; }
    .status-success { background-color: #d4edda; color: #155724; border-left: 5px solid #155724; }
    .status-failure { background-color: #f8d7da; color: #721c24; border-left: 5px solid #721c24; }
    .status-warning { background-color: #fff3cd; color: #856404; border-left: 5px solid #856404; }
    .status-reboot { background-color: #cfe2ff; color: #084298; border-left: 5px solid #084298; }
    .details-table table { width: 100%; border-collapse: collapse; margin-bottom: 15px; }
    .details-table th, .details-table td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    .details-table th { background-color: #f2f2f2; }
    pre { white-space: pre-wrap; word-wrap: break-word; background-color:#f5f5f5; border:1px solid #ccc; padding:5px; max-height: 200px; overflow-y: auto;}
    .footer { font-size: 0.8em; text-align: center; color: #777; margin-top: 20px; }
</style>
</head>
<body>
    <div class="container">
        <div class="header"><h2>${title}</h2></div>
        <div class="status ${status_class}">${status_message}</div>
        <div class="details-table">${details_html}</div>
        <div class="footer"><p>Report generated on ${current_timestamp} by $(hostname)</p></div>
    </div>
</body>
</html>
EOF
}

send_html_notification() {
    local subject_base="$1"
    local status_class="$2"      
    local status_message_text="$3" 
    local details_content_html="$4" 

    local full_subject="${HOSTNAME_LABEL} System Update: ${subject_base}"
    local html_body
    html_body=$(generate_email_html "${HOSTNAME_LABEL} - ${subject_base}" "$status_class" "$status_message_text" "$details_content_html")

    if [ ! -f "$MSMTP_CONFIG" ]; then
        log_message "ERROR" "msmtp configuration file not found: $MSMTP_CONFIG. Cannot send email."
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] - msmtp configuration file not found: $MSMTP_CONFIG. Email for '$full_subject' not sent." >> "$LOG_FILE" 
        return 1
    fi

    printf "To: %s\nSubject: %s\nContent-Type: text/html; charset=utf-8\nMIME-Version: 1.0\n\n%s" \
           "$RECIPIENT_EMAIL" "$full_subject" "$html_body" | \
    msmtp --file="$MSMTP_CONFIG" -a "$MSMTP_ACCOUNT" "$RECIPIENT_EMAIL"

    if [ $? -ne 0 ]; then 
        log_message "ERROR" "Failed to send email: $full_subject"
    else
        log_message "INFO" "Email sent successfully: $full_subject"
    fi
}

handle_error() {
    local exit_code="$1"
    local line_number="$2"
    local failed_command="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S') 
    
    local error_details_html="<p>Script failed on line ${line_number} with exit code ${exit_code} at ${timestamp}.</p>"
    error_details_html+="<p>Failed command:</p><pre>$(echo "$failed_command" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>" 
    error_details_html+="<h4>Log Snippet (Last 10 lines):</h4><pre>$(tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>" 

    log_message "ERROR" "Error on line $line_number: Exit code $exit_code. Command: $failed_command"
    send_html_notification "FAILURE" "status-failure" "❌ Script Execution Failed" "$error_details_html"
}

check_network() {
    local retry_count=0
    local max_retries=5 

    log_message "INFO" "Checking network connectivity..." 
    while [ $retry_count -lt $max_retries ]; do
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            log_message "INFO" "Network connectivity is OK." 
            return 0
        fi
        retry_count=$((retry_count + 1))
        log_message "WARNING" "Network check failed, attempt $retry_count of $max_retries. Retrying in 5s..." 
        sleep 5
    done
    log_message "ERROR" "Network connectivity check failed after $max_retries attempts." 
    return 1
}

initial_log_rotation() {
    if [ -f "$LOG_FILE" ]; then 
      for i in $(seq $((MAX_LOG_FILES-1)) -1 1); do # MAX_LOG_FILES-1 because .1.gz is the newest archive
        if [ -f "${LOG_FILE}.${i}.gz" ]; then
          mv "${LOG_FILE}.${i}.gz" "${LOG_FILE}.$((i+1)).gz"
        fi
      done
      if [ -s "$LOG_FILE" ]; then 
        gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz"
        truncate -s 0 "$LOG_FILE" 
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] - Main log rotated to ${LOG_FILE}.1.gz" >> "$LOG_FILE"
      fi
    else
      touch "$LOG_FILE" 
    fi
}
initial_log_rotation

# --- Main Script Execution ---
SCRIPT_MAIN_START_TIME=$(date '+%Y-%m-%d %H:%M:%S') 
log_message "INFO" "System update script started at: $SCRIPT_MAIN_START_TIME" 

if [[ $EUID -ne 0 ]]; then 
   log_message "ERROR" "This script must be run as root. Exiting."
   exit 1
fi

if ! command -v msmtp &> /dev/null; then
    log_message "WARNING" "msmtp is not installed. Attempting to install..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp; then
        log_message "INFO" "msmtp installed successfully."
    else
        log_message "ERROR" "Failed to install msmtp. Email notifications will not work."
    fi
fi

disk_warn_details="" 

CURRENT_DISK_USAGE_PERCENT=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//') 
if [ "$CURRENT_DISK_USAGE_PERCENT" -gt "$DISK_WARN_THRESHOLD" ]; then
    log_message "WARNING" "Disk space is at ${CURRENT_DISK_USAGE_PERCENT}%." 
    
    part1="<p>Current disk space usage is ${CURRENT_DISK_USAGE_PERCENT}%, which exceeds the warning threshold of ${DISK_WARN_THRESHOLD}%.</p>"
    part2="<table><tr><th>Filesystem</th><th>Size</th><th>Used</th><th>Avail</th><th>Use%</th><th>Mounted on</th></tr>"
    df_table_rows=$(df -h / | awk "NR==1 {print \"<tr><th>\" \$1 \"</th><th>\" \$2 \"</th><th>\" \$3 \"</th><th>\" \$4 \"</th><th>\" \$5 \"</th><th>\" \$6 \"</th></tr>\"} NR==2 {print \"<tr><td>\" \$1 \"</td><td>\" \$2 \"</td><td>\" \$3 \"</td><td>\" \$4 \"</td><td>\" \$5 \"</td><td>\" \$6 \"</td></tr>\"}")
    part3="</table>"

    disk_warn_details="${part1}${part2}${df_table_rows}${part3}"
    
    send_html_notification "Disk Space Warning" "status-warning" "⚠️ Disk Space High" "$disk_warn_details"
fi

if ! check_network; then
    net_fail_details="<p>Failed to establish network connectivity after several retries.</p><p>System updates cannot proceed without a working internet connection.</p>"
    send_html_notification "FAILURE - Network Down" "status-failure" "❌ Network Connectivity Failed" "$net_fail_details"
    exit 1
fi

AVAILABLE_SPACE_KB=$(df / | awk 'NR==2 {print $4}') 
MIN_SPACE_KB=500000 
if [ "$AVAILABLE_SPACE_KB" -lt "$MIN_SPACE_KB" ]; then
    log_message "ERROR" "Insufficient disk space for updates. Only ${AVAILABLE_SPACE_KB}KB available." 
    space_crit_details="<p>Insufficient disk space for updates. Only ${AVAILABLE_SPACE_KB}KB available, requires at least ${MIN_SPACE_KB}KB (500MB).</p>" 
    send_html_notification "FAILURE - Disk Space Critical" "status-failure" "❌ Insufficient Disk Space" "$space_crit_details"
    exit 1
fi
log_message "INFO" "Sufficient disk space available ($(numfmt --to=iec --suffix=B ${AVAILABLE_SPACE_KB}000))." 

log_message "INFO" "Updating package lists..." 
retries=0
update_success=false
last_apt_error=0 
while [ $retries -lt $MAX_RETRIES ] && [ $update_success = false ]; do
    if DEBIAN_FRONTEND=noninteractive apt-get update -o APT::Update::Error-Modes=any; then 
        update_success=true
        log_message "INFO" "Package list updated successfully." 
    else
        last_apt_error=$? 
        retries=$((retries + 1))
        log_message "WARNING" "apt-get update failed (exit code: $last_apt_error). Attempt $retries of $MAX_RETRIES." 
        if [ $retries -lt $MAX_RETRIES ]; then
            log_message "INFO" "Retrying in $RETRY_DELAY seconds..." 
            sleep $RETRY_DELAY
            log_message "INFO" "Clearing apt lists before retry..." 
            rm -rf /var/lib/apt/lists/*
            apt-get clean 
        fi
    fi
done

if [ $update_success = false ]; then
    log_message "ERROR" "Failed to update package list after $MAX_RETRIES attempts." 
    apt_fail_details="<p>Failed to update package lists (apt-get update) after $MAX_RETRIES attempts.</p><p>Last exit code: $last_apt_error</p>"
    send_html_notification "FAILURE - APT Update" "status-failure" "❌ APT Update Failed" "$apt_fail_details"
    exit 1
fi

log_message "INFO" "Starting full system upgrade (apt-get upgrade)..." 
if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" -y upgrade; then
    log_message "ERROR" "apt-get upgrade failed." 
    apt_upgrade_fail_details="<p>apt-get upgrade failed. Please check system logs for details.</p>"
    send_html_notification "FAILURE - APT Upgrade" "status-failure" "❌ APT Upgrade Failed" "$apt_upgrade_fail_details"
    exit 1
fi
log_message "INFO" "apt-get upgrade completed." 

log_message "INFO" "Starting distribution upgrade (apt-get dist-upgrade)..." 
if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade; then
    log_message "ERROR" "apt-get dist-upgrade failed." 
    apt_dist_upgrade_fail_details="<p>apt-get dist-upgrade failed. Please check system logs for details.</p>"
    send_html_notification "FAILURE - APT Dist-Upgrade" "status-failure" "❌ APT Dist-Upgrade Failed" "$apt_dist_upgrade_fail_details"
    exit 1
fi
log_message "INFO" "apt-get dist-upgrade completed." 

log_message "INFO" "Cleaning up old packages (autoremove, autoclean, clean)..." 
DEBIAN_FRONTEND=noninteractive apt-get -y autoremove
DEBIAN_FRONTEND=noninteractive apt-get -y autoclean
DEBIAN_FRONTEND=noninteractive apt-get -y clean
log_message "INFO" "Cleanup completed." 

sys_info_html="<h4>System Information:</h4>"
sys_info_html+="<p><strong>Disk Space:</strong></p><pre>$(df -h /)</pre>" 
sys_info_html+="<p><strong>Memory Usage:</strong></p><pre>$(free -h)</pre>" 
sys_info_html+="<p><strong>System Uptime:</strong></p><pre>$(uptime -p)</pre>" 
sys_info_html+="<p><strong>Last 5 Package Changes (dpkg.log):</strong></p><pre>$(grep -E 'install |upgrade |remove ' /var/log/dpkg.log | tail -n 5 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>" 

REBOOT_REQUIRED=false
if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=true
    log_message "INFO" "System requires a reboot." 
    send_html_notification "SUCCESS - Reboot Required" "status-reboot" "🔄 System Update Successful - Reboot Scheduled" "$sys_info_html<p>System will reboot automatically in 1 minute.</p>"
else
    log_message "INFO" "No reboot required." 
    send_html_notification "SUCCESS" "status-success" "✅ System Update Successful" "$sys_info_html"
fi

log_message "INFO" "Update completed successfully at $(date '+%Y-%m-%d %H:%M:%S')." 
log_message "INFO" "==================================" 

if [ "$REBOOT_REQUIRED" = true ]; then 
    log_message "INFO" "Rebooting system in 1 minute..." 
    shutdown -r +1 "System is rebooting after software update"
fi

# --- Final Log Cleanup ---
# Keeps the main log file and (MAX_LOG_FILES - 1) compressed archives.
# Example: if MAX_LOG_FILES is 5, keeps current log + log.1.gz, log.2.gz, log.3.gz, log.4.gz
log_message "INFO" "Performing final log archive cleanup..."
num_archives_to_keep=$((MAX_LOG_FILES - 1))
if [ $num_archives_to_keep -lt 0 ]; then 
    num_archives_to_keep=0; 
fi

# Count current .gz archives
current_archive_count=0
# Check if any .gz files exist before trying to count them
if ls -1q "$(dirname "$LOG_FILE")/$(basename "$LOG_FILE")."*.gz 2>/dev/null >/dev/null; then
    current_archive_count=$(ls -1q "$(dirname "$LOG_FILE")/$(basename "$LOG_FILE")."*.gz | wc -l)
fi

num_to_delete=$((current_archive_count - num_archives_to_keep))

if [ $num_to_delete -gt 0 ]; then
    log_message "INFO" "Found $current_archive_count archives. Keeping $num_archives_to_keep. Deleting $num_to_delete oldest archive(s)..."
    # List .gz files, sort by modification time (oldest first), take the number to delete, and remove them
    ls -1tr "$(dirname "$LOG_FILE")/$(basename "$LOG_FILE")."*.gz 2>/dev/null | head -n $num_to_delete | xargs -r rm
    if [ $? -eq 0 ]; then # Check xargs exit status
        log_message "INFO" "Successfully cleaned old log archives."
    else
        # xargs returns 123 if any invocation fails, 124 if utility not found, 125 if utility signals error
        # We can be more specific if needed, but for now, a general warning.
        log_message "WARNING" "Issues encountered during old log archive cleanup. Some files may not have been deleted."
    fi
else
    log_message "INFO" "No old log archives to clean beyond the configured limit ($num_archives_to_keep archives)."
fi

exit 0

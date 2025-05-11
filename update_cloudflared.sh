#!/bin/bash

# --- Configuration ---
DOCKER_COMPOSE_FILE="/home/dave/cloudflared/docker-compose.yml"
LOG_DIR="/home/dave/logs" 
LOG_FILE="${LOG_DIR}/cloudflared_update.log" 
MAX_LOG_ARCHIVES=5 
MSMTP_CONFIG="/home/dave/.msmtprc"
MSMTP_ACCOUNT="gandi" 
RECIPIENT_EMAIL="david@davidmagnus.co.uk"
HOSTNAME_LABEL="KH Pi 3" 

# --- Helper Functions ---

log_message() {
    local level="$1"
    local message="$2"
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" || { echo "CRITICAL: Failed to create log directory $LOG_DIR. Cannot log. Exiting." >&2; exit 1; }
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] - $message" >> "$LOG_FILE"
}

rotate_log_file() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" || { echo "CRITICAL: Failed to create log directory $LOG_DIR for rotation. Exiting." >&2; exit 1; }
    fi
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" || { echo "CRITICAL: Failed to touch log file $LOG_FILE for rotation. Exiting." >&2; exit 1; }
        return 
    fi

    for i in $(seq $((MAX_LOG_ARCHIVES - 1)) -1 1); do
        if [ -f "${LOG_FILE}.$i.gz" ]; then
            mv "${LOG_FILE}.$i.gz" "${LOG_FILE}.$((i + 1)).gz"
        fi
    done

    if [ -f "$LOG_FILE" ] && [ "$(wc -c <"$LOG_FILE")" -gt 0 ]; then 
        gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz"
        truncate -s 0 "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] - Log rotated. Previous log archived to ${LOG_FILE}.1.gz" >> "$LOG_FILE"
    fi
}

generate_html_email_body() {
    local title="$1"
    local status_class_arg="$2" # Changed: direct status class
    local status_message_arg="$3" # Changed: direct status message
    local details_html="$4"    
    local script_start_time="$5" # Arguments shifted
    local script_end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    local duration_msg="N/A"
    if [[ -n "$script_start_time" ]]; then
        local s_start=$(date -d "$script_start_time" +%s 2>/dev/null || date +%s)
        local s_end=$(date -d "$script_end_time" +%s 2>/dev/null || date +%s)
        if [[ "$s_start" =~ ^[0-9]+$ && "$s_end" =~ ^[0-9]+$ ]]; then
            local diff_seconds=$((s_end - s_start))
            duration_msg="$((diff_seconds / 60))m $((diff_seconds % 60))s"
        fi
    fi

    local log_snippet_html="<h4>Log Snippet (Last 10 lines):</h4><pre style='background-color:#f5f5f5; border:1px solid #ccc; padding:5px; overflow-x:auto;'>$(tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"

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
    .details-table { width: 100%; border-collapse: collapse; margin-bottom: 15px; }
    .details-table th, .details-table td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    .details-table th { background-color: #f2f2f2; }
    .log-snippet pre { white-space: pre-wrap; word-wrap: break-word; max-height: 200px; overflow-y: auto;}
    .footer { font-size: 0.8em; text-align: center; color: #777; margin-top: 20px; }
</style>
</head>
<body>
    <div class="container">
        <div class="header"><h2>${title}</h2></div>
        <div class="status ${status_class_arg}">${status_message_arg}</div>
        <h3>Details:</h3>
        ${details_html}
        <div class="log-snippet">${log_snippet_html}</div>
        <div class="footer">
            <p>Report generated on ${script_end_time} by $(hostname)<br>
            Script duration: ${duration_msg}</p>
        </div>
    </div>
</body>
</html>
EOF
}

send_html_email() {
    local subject_base="$1"
    local status_class="$2" 
    local status_message="$3" 
    local details_html="$4"
    local script_start_time="$5"

    local full_subject="${HOSTNAME_LABEL}: ${subject_base}"
    # Removed: local status_html_element="<p class='${status_class}'>${status_message}</p>"
    
    local html_body
    # Changed: Call generate_html_email_body with direct class and message
    html_body=$(generate_html_email_body "${HOSTNAME_LABEL} - ${subject_base}" "$status_class" "$status_message" "$details_html" "$script_start_time")

    if [ ! -f "$MSMTP_CONFIG" ]; then
        log_message "ERROR" "msmtp configuration file not found: $MSMTP_CONFIG. Cannot send email."
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

# --- Main Script ---
SCRIPT_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR" || { echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to create log directory $LOG_DIR. Exiting." >&2; exit 1; }

rotate_log_file 

log_message "INFO" "Starting Cloudflared Docker update check..."

for cmd_check in docker msmtp; do
    if ! command -v "$cmd_check" &> /dev/null; then
        log_message "ERROR" "$cmd_check is not installed. Please install $cmd_check and try again."
        send_html_email "Cloudflared Update Failure" "status-failure" "❌ Critical Error: $cmd_check not found" "<p>$cmd_check is not installed. Script cannot continue.</p>" "$SCRIPT_START_TIME"
        exit 1
    fi
done

if ! command -v docker compose &> /dev/null; then
     log_message "ERROR" "docker compose (v2) is not installed. Please install docker compose v2 and try again."
     send_html_email "Cloudflared Update Failure" "status-failure" "❌ Critical Error: docker compose not found" "<p>docker compose (v2) is not installed. Script cannot continue.</p>" "$SCRIPT_START_TIME"
     exit 1
fi

if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    log_message "ERROR" "Docker Compose file not found: $DOCKER_COMPOSE_FILE"
    send_html_email "Cloudflared Update Failure" "status-failure" "❌ Configuration Error" "<p>Docker Compose file not found at: ${DOCKER_COMPOSE_FILE}</p>" "$SCRIPT_START_TIME"
    exit 1
fi

log_message "INFO" "Pulling the latest Cloudflared Docker image..."
docker_pull_output=$(docker compose -f "$DOCKER_COMPOSE_FILE" pull 2>&1)
pull_exit_code=$?

details_html="<table class='details-table'><tr><th>Step</th><th>Status</th></tr>"
details_html+="<tr><td>Docker Image Pull</td>"

if [ $pull_exit_code -ne 0 ]; then
    log_message "ERROR" "Failed to pull the latest Cloudflared Docker image."
    log_message "ERROR" "Docker Pull Output: $docker_pull_output" 
    details_html+="<td style='color:red;'>Failed</td></tr></table>"
    details_html+="<h4>Docker Pull Output:</h4><pre style='background-color:#f5f5f5; border:1px solid #ccc; padding:5px;'>$(echo "$docker_pull_output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"
    send_html_email "Cloudflared Update Failure" "status-failure" "❌ Docker Image Pull Failed" "$details_html" "$SCRIPT_START_TIME"
    exit 1
fi
log_message "INFO" "Successfully pulled Cloudflared Docker image."
details_html+="<td style='color:green;'>Success</td></tr>"
details_html+="<tr><td colspan='2'><h4>Docker Pull Output (Last 20 lines):</h4><pre style='background-color:#f5f5f5; border:1px solid #ccc; padding:5px;'>$(echo "$docker_pull_output" | tail -n 20 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre></td></tr>"

log_message "INFO" "Recreating and restarting the Cloudflared container..."
docker_up_output=$(docker compose -f "$DOCKER_COMPOSE_FILE" up -d 2>&1)
up_exit_code=$?

details_html+="<tr><td>Container Restart</td>"
if [ $up_exit_code -ne 0 ]; then
    log_message "ERROR" "Failed to recreate and restart the Cloudflared container."
    log_message "ERROR" "Docker Up Output: $docker_up_output" 
    details_html+="<td style='color:red;'>Failed</td></tr></table>" 
    details_html+="<h4>Docker Up Output:</h4><pre style='background-color:#f5f5f5; border:1px solid #ccc; padding:5px;'>$(echo "$docker_up_output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"
    send_html_email "Cloudflared Update Failure" "status-failure" "❌ Container Restart Failed" "$details_html" "$SCRIPT_START_TIME"
    exit 1
fi

log_message "INFO" "Successfully recreated and restarted Cloudflared container."
details_html+="<td style='color:green;'>Success</td></tr></table>" 
details_html+="<h4>Docker Up Output (Last 20 lines):</h4><pre style='background-color:#f5f5f5; border:1px solid #ccc; padding:5px;'>$(echo "$docker_up_output" | tail -n 20 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"

log_message "INFO" "Cloudflared Docker container has been updated and restarted successfully."
send_html_email "Cloudflared Update Success" "status-success" "✅ Cloudflared Update Successful" "$details_html" "$SCRIPT_START_TIME"

exit 0

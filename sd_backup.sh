#!/bin/bash
set -e 

# --- Configuration ---
PI_CONFIG_FILE="$(dirname "$0")/pi_config.sh"
if [ -f "$PI_CONFIG_FILE" ]; then
    source "$PI_CONFIG_FILE"
fi

PI_EMAIL="${PI_EMAIL:-your-email@example.com}"
PI_USER="${PI_USER:-$(whoami)}"
PI_HOME="${PI_HOME:-$(eval echo ~$PI_USER)}"
PI_HOSTNAME="${PI_HOSTNAME:-$(hostname)}"
PI_MSMTP_CONFIG="${PI_MSMTP_CONFIG:-${PI_HOME}/.msmtprc}"
PI_RCLONE_CONFIG="${PI_RCLONE_CONFIG:-${PI_HOME}/.config/rclone/rclone.conf}"
PI_BACKUP_REMOTE="${PI_BACKUP_REMOTE:-gdrive}" 
PI_CLOUD_FOLDER="${PI_CLOUD_FOLDER:-pi_backups_${PI_HOSTNAME}}" 

BACKUP_DIR="${PI_HOME}" 
LOG_DIR="${PI_HOME}/logs" 
LOG_FILE="${LOG_DIR}/${PI_HOSTNAME}_sd_backup.log" 
EXCLUDE_FILE="$(dirname "$0")/sd_backup_excludes.txt" 
MAX_LOG_ARCHIVES=5
MAX_CLOUD_BACKUPS=2 

# --- Helper Functions ---
mkdir -p "$LOG_DIR" || { echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to create log directory $LOG_DIR. Exiting." >&2; exit 1; }

log_message() {
    local level="$1"; local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] - $message" | tee -a "$LOG_FILE"
}

initial_log_rotation() {
    if [ ! -f "$LOG_FILE" ]; then touch "$LOG_FILE" || { echo "CRITICAL: Failed to touch $LOG_FILE" >&2; exit 1; }; fi
    if [ -s "$LOG_FILE" ]; then 
      for i in $(seq $((MAX_LOG_ARCHIVES-1)) -1 1); do
        if [ -f "${LOG_FILE}.${i}.gz" ]; then mv "${LOG_FILE}.${i}.gz" "${LOG_FILE}.$((i+1)).gz"; fi
      done
      gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz"; truncate -s 0 "$LOG_FILE" 
      echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] - Main log rotated to ${LOG_FILE}.1.gz" >> "$LOG_FILE"
    fi
}

generate_backup_email_html() {
    local title="$1"; local status_class="$2"; local status_message="$3"; 
    local details_html="$4"; local script_start_time="$5"
    local script_end_time=$(date '+%Y-%m-%d %H:%M:%S'); local duration_msg="N/A"
    if [[ -n "$script_start_time" ]]; then
        local s_start=$(date -d "$script_start_time" +%s 2>/dev/null || date +%s)
        local s_end=$(date -d "$script_end_time" +%s 2>/dev/null || date +%s)
        if [[ "$s_start" =~ ^[0-9]+$ && "$s_end" =~ ^[0-9]+$ ]]; then
            local diff_seconds=$((s_end - s_start)); duration_msg="$((diff_seconds/60))m $((diff_seconds%60))s"
        fi
    fi
    local log_snippet="<h4>Log Snippet (Last 15 lines):</h4><pre>$(tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</pre>"
    cat <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font-family:Arial,sans-serif;margin:10px;background-color:#f4f4f4;color:#333}.container{max-width:650px;margin:20px auto;background-color:#fff;padding:20px;border-radius:8px;box-shadow:0 0 15px rgba(0,0,0,.1)}.header{background-color:#2c3e50;color:#fff;padding:15px;text-align:center;border-radius:8px 8px 0 0}.header h2{margin:0}.status{padding:15px;margin:20px 0;border-radius:5px;font-size:1.1em;text-align:center;font-weight:700}.status-success{background-color:#d4edda;color:#155724;border-left:6px solid #28a745}.status-failure{background-color:#f8d7da;color:#721c24;border-left:6px solid #dc3545}.status-warning{background-color:#fff3cd;color:#856404;border-left:6px solid #ffc107}table{width:100%;border-collapse:collapse;margin-bottom:15px}th,td{border:1px solid #ddd;padding:8px;text-align:left;font-size:.9em}th{background-color:#f2f2f2}pre{white-space:pre-wrap;word-wrap:break-word;background-color:#f5f5f5;border:1px solid #ccc;padding:10px;max-height:250px;overflow-y:auto;border-radius:4px}.footer{font-size:.85em;text-align:center;color:#6c757d;margin-top:25px;border-top:1px solid #eee;padding-top:15px}</style></head><body><div class="container"><div class="header"><h2>${title}</h2></div><div class="status ${status_class}">${status_message}</div>${details_html}${log_snippet}<div class="footer"><p>Report generated on ${script_end_time} by ${PI_HOSTNAME}<br>Script duration: ${duration_msg}</p></div></div></body></html>
EOF
}

send_html_email() {
    local subject_base="$1"; local status_class="$2"; local status_message_text="$3"; 
    local details_content_html="$4"; local start_time="$5"
    local full_subject="${PI_HOSTNAME} SD Backup: ${subject_base}"
    local html_body=$(generate_backup_email_html "${PI_HOSTNAME} SD Backup" "$status_class" "$status_message_text" "$details_content_html" "$start_time")
    if [ ! -f "$PI_MSMTP_CONFIG" ]; then log_message "ERROR" "msmtp config not found: $PI_MSMTP_CONFIG"; return 1; fi
    printf "To:%s\nSubject:%s\nContent-Type:text/html;charset=utf-8\nMIME-Version:1.0\n\n%s" "$PI_EMAIL" "$full_subject" "$html_body" | msmtp --file="$PI_MSMTP_CONFIG" -a default "$PI_EMAIL"
    if [ $? -ne 0 ]; then log_message "ERROR" "msmtp send failed for: $full_subject"; else log_message "INFO" "Email sent for: $full_subject"; fi
}

# Trap handler variable to prevent double emails
_EMAIL_SENT_BY_TRAP=false

cleanup_and_exit() {
    local exit_status="$1"
    local trap_message_detail="$2" # Message from trap, includes line number etc.

    log_message "INFO" "Running cleanup (invoked by trap or explicit call)..."
    [ -d "$TEMP_DIR" ] && sudo rm -rf "$TEMP_DIR" && log_message "INFO" "Temporary directory $TEMP_DIR removed."

    # Only send email from trap if it's a failure and email hasn't been sent by this trap already
    if [ "$exit_status" -ne 0 ] && [ "$_EMAIL_SENT_BY_TRAP" = false ]; then
        _EMAIL_SENT_BY_TRAP=true # Mark that trap is sending an email
        email_subject_base="FAILURE"
        email_status_class="status-failure"
        email_status_message="❌ Backup Process Failed"
        email_details_html="<p>The backup process encountered an error. Please check the logs on the server: ${LOG_FILE}</p>"
        if [ -n "$trap_message_detail" ]; then 
            email_details_html+="<p>Error detail: $(echo "$trap_message_detail" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</p>"
        fi
        
        # Check if backup file exists; if so, mention it's preserved
        if [ -f "$BACKUP_FILE" ]; then # Check if BACKUP_FILE is defined and exists
            log_message "WARNING" "Backup file $BACKUP_FILE may exist but process failed. Not deleting."
            email_details_html+="<p>Local backup file $BACKUP_FILE may have been created and is preserved.</p>"
        fi
        send_html_email "$email_subject_base" "$email_status_class" "$email_status_message" "$email_details_html" "$SCRIPT_START_TIME"
    fi
    log_message "INFO" "Script finished with exit status $exit_status."
    exit "$exit_status" # Exit with the original status
}
# Added BASH_COMMAND to trap for more context on error
trap 'cleanup_and_exit $? "Trap caught signal or error at line $LINENO. Command: $BASH_COMMAND"' EXIT HUP INT QUIT TERM


# --- Main Script ---
SCRIPT_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
initial_log_rotation
DATE=$(date +"%Y-%m-%d_%H-%M-%S") 
TEMP_DIR="${BACKUP_DIR}/temp_backup_${DATE}" 
BACKUP_FILE="${BACKUP_DIR}/${PI_HOSTNAME}_backup_${DATE}.tar.gz"
log_message "INFO" "Starting backup process for $PI_HOSTNAME to $BACKUP_FILE"
DRY_RUN=false
if [[ "$1" == "-d" || "$1" == "--dry-run" ]]; then DRY_RUN=true; log_message "INFO" "Running in DRY-RUN mode."; fi

for cmd in rsync tar rclone msmtp sudo; do 
    if ! command -v $cmd &> /dev/null; then log_message "ERROR" "$cmd not installed."; exit 1; fi # Let trap handle email
done
if [ ! -f "$EXCLUDE_FILE" ]; then log_message "ERROR" "Exclude file $EXCLUDE_FILE not found!"; exit 1; fi # Let trap handle email

if [ "$DRY_RUN" = false ]; then
    log_message "INFO" "Performing pre-backup system cleanup..."
    sudo apt-get clean -qq || log_message "WARNING" "apt-get clean failed"
    sudo apt-get autoremove -y -qq || log_message "WARNING" "apt-get autoremove failed"
    sudo journalctl --vacuum-time=3d || log_message "WARNING" "journalctl vacuum failed"
    rm -rf "${PI_HOME}/.cache/"* || log_message "WARNING" "Failed to clear user .cache"
    log_message "INFO" "System cleanup finished."
else log_message "INFO" "[Dry Run] Would perform system cleanup."; fi

log_message "INFO" "Creating temporary directory for backup: $TEMP_DIR"
mkdir -p "$TEMP_DIR" || exit 1 # Let trap handle email

log_message "INFO" "Creating filesystem backup using rsync..."
rsync_cmd="sudo rsync -aAX --delete --one-file-system --exclude-from=\"$EXCLUDE_FILE\" --exclude=\"$TEMP_DIR/\" / \"$TEMP_DIR/\""
if [ "$DRY_RUN" = true ]; then log_message "INFO" "[Dry Run] Would execute: $rsync_cmd";
else
    if eval "$rsync_cmd"; then log_message "INFO" "Filesystem backup created successfully in $TEMP_DIR";
    else log_message "ERROR" "Rsync failed."; exit 1; fi # Let trap handle email
fi

log_message "INFO" "Creating compressed tarball: $BACKUP_FILE"
tar_cmd_base="sudo tar -C \"$TEMP_DIR\" -cpf - ."
compression_cmd="gzip -c > \"$BACKUP_FILE\""; if command -v pigz &>/dev/null; then compression_cmd="pigz -c > \"$BACKUP_FILE\""; fi
full_tar_cmd="$tar_cmd_base | $compression_cmd"
if [ "$DRY_RUN" = true ]; then log_message "INFO" "[Dry Run] Would execute: $full_tar_cmd";
else
    if eval "$full_tar_cmd"; then log_message "INFO" "Backup tarball created: $BACKUP_FILE";
    else log_message "ERROR" "Tarball creation failed."; exit 1; fi # Let trap handle email
fi

log_message "INFO" "Cleaning up temporary rsync directory: $TEMP_DIR"
sudo rm -rf "$TEMP_DIR"

BACKUP_SIZE="N/A"
if [ "$DRY_RUN" = false ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1); log_message "INFO" "Backup file size: $BACKUP_SIZE"
    log_message "INFO" "Changing ownership of $BACKUP_FILE to $PI_USER..."
    sudo chown "${PI_USER}:${PI_USER}" "$BACKUP_FILE" || log_message "WARNING" "Failed to chown $BACKUP_FILE"
fi

log_message "DEBUG" "PI_BACKUP_REMOTE value is: '${PI_BACKUP_REMOTE}'"
log_message "DEBUG" "PI_CLOUD_FOLDER value is: '${PI_CLOUD_FOLDER}'"
log_message "INFO" "Uploading backup to cloud: ${PI_BACKUP_REMOTE}:${PI_CLOUD_FOLDER}"
rclone_cmd="sudo -u \"$PI_USER\" rclone --config=\"$PI_RCLONE_CONFIG\" copy -v \"$BACKUP_FILE\" \"${PI_BACKUP_REMOTE}:${PI_CLOUD_FOLDER}/\""
log_message "DEBUG" "Constructed rclone command: $rclone_cmd"

if [ "$DRY_RUN" = true ]; then log_message "INFO" "[Dry Run] Would execute rclone copy."
else
    if eval "$rclone_cmd"; then
        log_message "INFO" "Backup file uploaded successfully."
        log_message "INFO" "Cleaning up local backup file: $BACKUP_FILE"
        rm -f "$BACKUP_FILE" || log_message "WARNING" "Failed to rm $BACKUP_FILE"
    else
        log_message "ERROR" "Rclone upload failed. Local file $BACKUP_FILE preserved."
        # Removed explicit call to cleanup_and_exit. Let trap handle it via exit 1.
        exit 1 
    fi
fi

if [ "$DRY_RUN" = false ]; then
    log_message "INFO" "Managing cloud backups (keep last $MAX_CLOUD_BACKUPS)..."
    files_to_delete=$(sudo -u "$PI_USER" rclone --config="$PI_RCLONE_CONFIG" lsf --format "t;p" "${PI_BACKUP_REMOTE}:${PI_CLOUD_FOLDER}/" | sort -t';' -k1 | head -n -$MAX_CLOUD_BACKUPS | cut -d';' -f2)
    if [ -n "$files_to_delete" ]; then
        log_message "INFO" "Old cloud backups to delete:"
        echo "$files_to_delete" | while IFS= read -r file_to_delete; do
            log_message "INFO" "- $file_to_delete"
            delete_rclone_cmd="sudo -u \"$PI_USER\" rclone --config=\"$PI_RCLONE_CONFIG\" delete \"${PI_BACKUP_REMOTE}:${PI_CLOUD_FOLDER}/$file_to_delete\""
            if eval "$delete_rclone_cmd"; then log_message "INFO" "  Deleted: $file_to_delete";
            else log_message "WARNING" "  Failed to delete: $file_to_delete"; fi
        done
    else log_message "INFO" "No old cloud backups to delete."; fi
fi

log_message "INFO" "Backup process finished successfully."
success_details_html="<p>The SD card backup process completed successfully.</p>"
if [ "$DRY_RUN" = false ]; then success_details_html+="<p><strong>Backup Size:</strong> $BACKUP_SIZE</p><p><strong>Cloud Location:</strong> ${PI_BACKUP_REMOTE}:${PI_CLOUD_FOLDER}</p>"; fi

# Mark that this trap invocation should NOT send an email if we are on success path
_EMAIL_SENT_BY_TRAP=true 
send_html_email "SUCCESS" "status-success" "✅ Backup Successful" "$success_details_html" "$SCRIPT_START_TIME"

# Explicitly remove trap for EXIT before successful exit, so it doesn't run cleanup_and_exit again
trap - EXIT
exit 0 

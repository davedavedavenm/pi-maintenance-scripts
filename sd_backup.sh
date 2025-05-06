#!/bin/bash
set -e

# Load configuration
if [ -f "$(dirname "$0")/pi_config.sh" ]; then
    source "$(dirname "$0")/pi_config.sh"
else
    # Fallback configuration if config file is missing
    PI_EMAIL="your-email@example.com"
    PI_USER="$(whoami)"
    PI_HOME="/home/${PI_USER}"
    PI_HOSTNAME="$(hostname)"
    PI_MSMTP_CONFIG="${PI_HOME}/.msmtprc"
    PI_RCLONE_CONFIG="${PI_HOME}/.config/rclone/rclone.conf"
    PI_BACKUP_REMOTE="gdrive"
    PI_CLOUD_FOLDER="pi_backups_${PI_HOSTNAME}"
fi

# Define variables
DATE=$(date +"%d-%m-%Y_%H-%M-%S")
BACKUP_DIR="${PI_HOME}"
PI_NAME="${PI_HOSTNAME}"
CLOUD_FOLDER="${PI_CLOUD_FOLDER}"
BACKUP_FILE="${BACKUP_DIR}/${PI_NAME}_backup_${DATE}.tar.gz"
LOGFILE="${BACKUP_DIR}/${PI_NAME}_backup.log"
TEMP_EMAIL="/tmp/backup-email-${DATE}.txt"
EMAIL="${PI_EMAIL}"
REMOTE_NAME="${PI_BACKUP_REMOTE}"
TEMP_DIR="${BACKUP_DIR}/temp_backup"
MSMTP_CONFIG="${PI_MSMTP_CONFIG}"
RCLONE_CONFIG="${PI_RCLONE_CONFIG}"

# Function to log messages
log_message() {
    echo "$1"
    echo "$(date +"%d/%m/%Y %H:%M:%S") - $1" >> "$LOGFILE"
}

# Function to send email
send_email() {
    local subject="$1"
    local message="$2"
    echo -e "To: $EMAIL\nSubject: $subject\n\n$message" > "$TEMP_EMAIL"
    cat "$LOGFILE" >> "$TEMP_EMAIL"
    /usr/bin/msmtp -C "$MSMTP_CONFIG" -a default "$EMAIL" < "$TEMP_EMAIL"
    rm -f "$TEMP_EMAIL"
}

# Function for cleanup
cleanup() {
    log_message "Cleaning up..."
    [ -d "$TEMP_DIR" ] && sudo rm -rf "$TEMP_DIR"
    [ -f "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE"
}

# Ensure required commands are available
for cmd in rsync tar rclone msmtp; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is not installed." >&2
        exit 1
    fi
done

# Parse command line options
DRY_RUN=false
while getopts ":d" opt; do
    case ${opt} in
        d ) DRY_RUN=true ;;
        \? ) echo "Usage: $0 [-d]" >&2; exit 1 ;;
    esac
done

# Start logging
log_message "Starting backup process for $PI_NAME"
[ "$DRY_RUN" = true ] && log_message "Running in dry-run mode"

# Perform pre-backup cleanup
log_message "Performing pre-backup cleanup..."
if [ "$DRY_RUN" = false ]; then
    sudo apt-get clean
    sudo apt-get autoremove -y
    sudo journalctl --vacuum-time=3d
    rm -rf ${PI_HOME}/.cache/*
else
    log_message "[Dry run] Would perform system cleanup"
fi

# Create temporary directory
log_message "Creating temporary directory for backup..."
mkdir -p "$TEMP_DIR"

# Create backup using rsync
log_message "Creating filesystem backup using rsync..."
if [ "$DRY_RUN" = false ]; then
    if sudo rsync -aAXv --one-file-system --exclude={"${PI_HOME}/Downloads","${PI_HOME}/.cache","${PI_HOME}/.config/chromium","/proc","/sys","/dev","/tmp","/run","/var/cache","/var/tmp","/var/lib/plexmediaserver","$TEMP_DIR"} / "$TEMP_DIR"; then
        log_message "Filesystem backup created successfully in $TEMP_DIR"
    else
        log_message "Failed to create filesystem backup using rsync"
        send_email "$PI_NAME Backup Failed" "Backup failed during filesystem backup creation."
        cleanup
        exit 1
    fi
else
    log_message "[Dry run] Would create filesystem backup using rsync"
fi

# Create tarball of the rsynced data
log_message "Creating compressed tarball of the backup..."
if [ "$DRY_RUN" = false ]; then
    if command -v pigz > /dev/null; then
        if sudo tar -I pigz -cf "$BACKUP_FILE" -C "$TEMP_DIR" .; then
            log_message "Filesystem backup tarball created successfully using pigz: $BACKUP_FILE"
        else
            log_message "Failed to create filesystem backup tarball using pigz"
            send_email "$PI_NAME Backup Failed" "Backup failed during filesystem backup tarball creation."
            cleanup
            exit 1
        fi
    else
        if sudo tar -czf "$BACKUP_FILE" -C "$TEMP_DIR" .; then
            log_message "Filesystem backup tarball created successfully using gzip: $BACKUP_FILE"
        else
            log_message "Failed to create filesystem backup tarball using gzip"
            send_email "$PI_NAME Backup Failed" "Backup failed during filesystem backup tarball creation."
            cleanup
            exit 1
        fi
    fi
else
    log_message "[Dry run] Would create compressed tarball of the backup"
fi

# Clean up temporary directory
log_message "Cleaning up temporary directory..."
sudo rm -rf "$TEMP_DIR"

# Get the size of the backup file
if [ "$DRY_RUN" = false ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log_message "Backup file size: $BACKUP_SIZE"
else
    log_message "[Dry run] Would calculate backup file size"
fi

# Change ownership of the backup file
log_message "Changing ownership of backup file..."
if [ "$DRY_RUN" = false ]; then
    if sudo chown ${PI_USER}:${PI_USER} "$BACKUP_FILE"; then
        log_message "Ownership of backup file changed to ${PI_USER}"
    else
        log_message "Failed to change ownership of backup file"
        send_email "$PI_NAME Backup Failed" "Backup failed during changing ownership."
        cleanup
        exit 1
    fi
else
    log_message "[Dry run] Would change ownership of backup file"
fi

# Upload to cloud storage
log_message "Uploading to cloud storage..."
if [ "$DRY_RUN" = false ]; then
    if sudo -u ${PI_USER} rclone --config="$RCLONE_CONFIG" copy -v "$BACKUP_FILE" "$REMOTE_NAME:$CLOUD_FOLDER"; then
        log_message "Backup file uploaded to cloud storage successfully"
    else
        log_message "Failed to upload backup file to cloud storage"
        send_email "$PI_NAME Backup Failed" "Backup failed during upload to cloud storage."
        cleanup
        exit 1
    fi
else
    log_message "[Dry run] Would upload backup file to cloud storage"
fi

# Clean up the local backup file
log_message "Cleaning up the local backup file..."
if [ "$DRY_RUN" = false ]; then
    if rm -f "$BACKUP_FILE"; then
        log_message "Local backup file removed successfully"
    else
        log_message "Failed to remove the local backup file"
        send_email "$PI_NAME Backup Warning" "Backup completed but failed to clean up the local backup file."
    fi
else
    log_message "[Dry run] Would remove local backup file"
fi

# Keep only the two most recent backups in the cloud storage
log_message "Managing backups in cloud storage..."
if [ "$DRY_RUN" = false ]; then
    BACKUP_COUNT=$(sudo -u ${PI_USER} rclone --config="$RCLONE_CONFIG" lsf "$REMOTE_NAME:$CLOUD_FOLDER" | wc -l)
    if [ "$BACKUP_COUNT" -le 2 ]; then
        log_message "Less than or equal to 2 backups found. No backups will be deleted."
    else
        log_message "More than 2 backups found. Removing older backups..."
        if sudo -u ${PI_USER} rclone --config="$RCLONE_CONFIG" lsf --format "tp" "$REMOTE_NAME:$CLOUD_FOLDER" | sort -r | tail -n +3 | while read -r line; do
            file=$(echo "$line" | cut -d';' -f2)
            sudo -u ${PI_USER} rclone --config="$RCLONE_CONFIG" delete "$REMOTE_NAME:$CLOUD_FOLDER/$file"
        done; then
            log_message "Old backups removed from cloud storage successfully"
        else
            log_message "Failed to remove old backups from cloud storage"
            send_email "$PI_NAME Backup Warning" "Backup completed but failed to remove old backups from cloud storage."
        fi
    fi
else
    log_message "[Dry run] Would manage backups in cloud storage"
fi

# Log completion
log_message "Backup process finished"

# Send success email
if [ "$DRY_RUN" = false ]; then
    send_email "$PI_NAME Backup Successful" "Backup completed successfully.\nBackup file size: $BACKUP_SIZE"
else
    log_message "[Dry run] Would send success email"
fi

# Final cleanup
[ "$DRY_RUN" = false ] && cleanup
log_message "Script execution completed"

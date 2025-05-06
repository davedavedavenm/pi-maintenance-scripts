#!/bin/bash
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
fi

# Script configuration
LOGFILE="${PI_HOME}/update-and-restart.log"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
EMAIL="${PI_EMAIL}"
SUBJECT_SUCCESS="${PI_HOSTNAME} Update Successful"
SUBJECT_FAILURE="${PI_HOSTNAME} Update Failed"
SUBJECT_REBOOT="${PI_HOSTNAME} Update and Reboot"
TEMP_EMAIL="/tmp/email.txt"
DISK_WARN_THRESHOLD=90
MAX_RETRIES=3
RETRY_DELAY=5
MAX_LOG_FILES=3

# Set error handling
set -euo pipefail
trap 'handle_error $? $LINENO' ERR

# Error handling function
handle_error() {
    local exit_code=$1
    local line_number=$2
    echo "Error on line $line_number: Exit code $exit_code"
    echo -e "To: $EMAIL\nSubject: $SUBJECT_FAILURE\n\nScript failed on line $line_number with exit code $exit_code at: $TIMESTAMP" > $TEMP_EMAIL
    msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL < $TEMP_EMAIL
    exit $exit_code
}

# Function to check network connectivity
check_network() {
    local retry_count=0
    local max_retries=5
    
    while [ $retry_count -lt $max_retries ]; do
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            return 0
        fi
        retry_count=$((retry_count + 1))
        echo "Network check failed, attempt $retry_count of $max_retries"
        sleep 5
    done
    
    return 1
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Ensure log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Rotate logs
if [ -f "$LOGFILE" ]; then
    for i in $(seq $((MAX_LOG_FILES-1)) -1 1); do
        if [ -f "${LOGFILE}.$i" ]; then
            mv "${LOGFILE}.$i" "${LOGFILE}.$((i+1))"
        fi
    done
    mv "$LOGFILE" "${LOGFILE}.1"
fi

# Check if msmtp is installed
if ! command -v msmtp &> /dev/null; then
    echo "msmtp is not installed. Installing..."
    apt-get install -y msmtp
fi

# Check disk space before starting
DISK_SPACE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$DISK_SPACE" -gt "$DISK_WARN_THRESHOLD" ]; then
    echo -e "To: $EMAIL\nSubject: Disk Space Warning\n\nDisk space is at $DISK_SPACE%" > $TEMP_EMAIL
    msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL < $TEMP_EMAIL
fi

{
    echo "=================================="
    echo "Update started at: $TIMESTAMP"
    
    # Check network connectivity first
    echo "Checking network connectivity..."
    if ! check_network; then
        echo "Network connectivity check failed."
        echo -e "To: $EMAIL\nSubject: $SUBJECT_FAILURE\n\nUpdate failed - No network connectivity at: $TIMESTAMP" > $TEMP_EMAIL
        msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL < $TEMP_EMAIL
        exit 1
    fi
    
    # Check available disk space for updates
    AVAILABLE_SPACE=$(df / | awk 'NR==2 {print $4}')
    if [ "$AVAILABLE_SPACE" -lt 500000 ]; then  # Less than 500MB
        echo "Insufficient disk space for updates."
        echo -e "To: $EMAIL\nSubject: Disk Space Critical\n\nInsufficient space for updates. Only ${AVAILABLE_SPACE}KB available." > $TEMP_EMAIL
        msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL < $TEMP_EMAIL
        exit 1
    fi
    
    # Update with retry logic
    retries=0
    update_success=false
    
    while [ $retries -lt $MAX_RETRIES ] && [ $update_success = false ]; do
        if apt-get update; then
            update_success=true
            echo "Package list updated successfully."
        else
            retries=$((retries + 1))
            if [ $retries -lt $MAX_RETRIES ]; then
                echo "Update failed, retrying in $RETRY_DELAY seconds... (Attempt $retries of $MAX_RETRIES)"
                sleep $RETRY_DELAY
                # Clear apt lists before retrying
                rm -rf /var/lib/apt/lists/*
                apt clean
            fi
        fi
    done
    if [ $update_success = false ]; then
        echo "Failed to update package list after $MAX_RETRIES attempts."
        echo -e "To: $EMAIL\nSubject: $SUBJECT_FAILURE\n\nUpdate failed after $MAX_RETRIES attempts at: $TIMESTAMP" > $TEMP_EMAIL
        msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL < $TEMP_EMAIL
        exit 1
    fi
    # Full system upgrade
    echo "Starting full system upgrade..."
    
    # Upgrade all packages
    if ! apt-get -y upgrade; then
        echo "Failed to upgrade packages."
        echo -e "To: $EMAIL\nSubject: $SUBJECT_FAILURE\n\nUpdate failed at: $TIMESTAMP" > $TEMP_EMAIL
        msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL < $TEMP_EMAIL
        exit 1
    fi
    
    # Perform distribution upgrade
    if ! apt-get -y dist-upgrade; then
        echo "Failed to perform distribution upgrade."
        echo -e "To: $EMAIL\nSubject: $SUBJECT_FAILURE\n\nDist-upgrade failed at: $TIMESTAMP" > $TEMP_EMAIL
        msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL < $TEMP_EMAIL
        exit 1
    fi
    # Clean up
    echo "Cleaning up old packages..."
    apt-get -y autoremove
    apt-get -y autoclean
    apt-get clean
    # Check if reboot is needed
    REBOOT_REQUIRED=false
    if [ -f /var/run/reboot-required ]; then
        REBOOT_REQUIRED=true
        echo "System requires a reboot."
        {
            echo -e "To: $EMAIL"
            echo -e "Subject: $SUBJECT_REBOOT"
            echo -e "\nUpdate completed successfully at: $TIMESTAMP"
            echo -e "\nSystem will reboot automatically."
            echo -e "\nSystem Information:"
            echo -e "-------------------"
            echo -e "Disk Space:"
            df -h /
            echo -e "\nMemory Usage:"
            free -h
            echo -e "\nSystem Uptime:"
            uptime
            echo -e "\nLast 5 package updates:"
            if [ -f /var/log/dpkg.log ] && grep "install " /var/log/dpkg.log >/dev/null 2>&1; then
                grep "install " /var/log/dpkg.log | tail -n 5
            else
                echo "No recent package installations found"
            fi
        } > $TEMP_EMAIL
    else
        echo "No reboot required."
        {
            echo -e "To: $EMAIL"
            echo -e "Subject: $SUBJECT_SUCCESS"
            echo -e "\nUpdate completed successfully at: $TIMESTAMP"
            echo -e "\nSystem Information:"
            echo -e "-------------------"
            echo -e "Disk Space:"
            df -h /
            echo -e "\nMemory Usage:"
            free -h
            echo -e "\nSystem Uptime:"
            uptime
            echo -e "\nLast 5 package updates:"
            if [ -f /var/log/dpkg.log ] && grep "install " /var/log/dpkg.log >/dev/null 2>&1; then
                grep "install " /var/log/dpkg.log | tail -n 5
            else
                echo "No recent package installations found"
            fi
        } > $TEMP_EMAIL
    fi
    msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL < $TEMP_EMAIL
    echo "Update completed successfully."
    echo "=================================="
    # Reboot if required
    if [ "$REBOOT_REQUIRED" = true ]; then
        echo "Rebooting system in 1 minute..."
        shutdown -r +1 "System is rebooting after software update"
    fi
} | tee -a "$LOGFILE"

# Clean up old logs (keep only MAX_LOG_FILES number of logs)
find "$(dirname "$LOGFILE")" -name "$(basename "$LOGFILE")*" -type f | sort -r | tail -n +$((MAX_LOG_FILES+1)) | xargs -r rm

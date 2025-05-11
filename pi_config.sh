#!/bin/bash
# Configuration file for Pi maintenance scripts
# Edit these values to match your setup

# Basic info
PI_EMAIL="david@davidmagnus.co.uk"  # Your email address
PI_USER="$(whoami)"                 # Current username
PI_HOSTNAME="$(hostname)"           # System hostname

# Paths
PI_HOME="/home/${PI_USER}"          # Home directory 
PI_LOGS_DIR="${PI_HOME}"            # Where to store logs
PI_MSMTP_CONFIG="${PI_HOME}/.msmtprc"  # Path to msmtp config
PI_RCLONE_CONFIG="${PI_HOME}/.config/rclone/rclone.conf"  # Path to rclone config

# Backup configuration (keeps existing values if script is run on your-pi-hostname)
if [[ "${PI_HOSTNAME}" == "gdrive" ]]; then
    # Use existing values for this Pi
    PI_BACKUP_REMOTE="gdrive"           # Existing rclone remote name
    PI_CLOUD_FOLDER="pi_backups_khpi3"  # Existing cloud folder
else
    # Default values for other systems
    PI_BACKUP_REMOTE="gdrive"           # Default rclone remote name
    PI_CLOUD_FOLDER="pi_backups_${PI_HOSTNAME}"  # Dynamic folder name
fi

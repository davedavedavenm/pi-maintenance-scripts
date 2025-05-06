#!/bin/bash
#
# Pi System Status Script
# Provides weekly system status reports via email
#
# Version: 1.0
# Author: Dave (adapted from Claude script)
# License: MIT

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

# Configuration variables
EMAIL_TO="${PI_EMAIL}"
HOSTNAME="${PI_HOSTNAME}"
SUBJECT="${HOSTNAME} Weekly Status Report"
TEMP_EMAIL="/tmp/status-email.txt"
LOG_DIR="${PI_HOME}"  # Directory where logs are stored
UPDATE_LOG="${LOG_DIR}/update-and-restart.log"
BACKUP_LOG="${LOG_DIR}/${HOSTNAME}_backup.log"

# Check if backup log exists, use alternative naming if needed
if [ ! -f "$BACKUP_LOG" ]; then
    BACKUP_LOG=$(find "$LOG_DIR" -name "*backup.log" -type f | head -1)
fi

# Function to check if service is active
check_service() {
    local service=$1
    if systemctl is-active --quiet $service; then
        echo "✅ Active"
    else
        echo "❌ Inactive"
    fi
}

# Check if recent backups exist
BACKUP_STATUS="❌ ALERT: No recent backup found!"
if [ -f "$BACKUP_LOG" ]; then
    LAST_BACKUP=$(grep -a "Backup process finished\|backup completed successfully" "$BACKUP_LOG" 2>/dev/null | tail -1)
    if [[ ! -z "$LAST_BACKUP" ]]; then
        BACKUP_DATE=$(echo "$LAST_BACKUP" | grep -oE "[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}")
        BACKUP_STATUS="✅ Last backup completed on $BACKUP_DATE"
    fi
fi

# Check if updates are running
UPDATE_STATUS="❌ ALERT: No recent updates found!"
if [ -f "$UPDATE_LOG" ]; then
    LAST_UPDATE=$(grep -a "Update completed successfully\|upgrade completed" "$UPDATE_LOG" 2>/dev/null | tail -1)
    if [[ ! -z "$LAST_UPDATE" ]]; then
        UPDATE_DATE=$(echo "$LAST_UPDATE" | grep -oE "[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}")
        if [[ ! -z "$UPDATE_DATE" ]]; then
            UPDATE_STATUS="✅ Last update completed on $UPDATE_DATE"
        else
            UPDATE_STATUS="✅ Updates are running successfully"
        fi
    fi
fi

# Get system stats
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}')
DISK_FREE=$(df -h / | awk 'NR==2 {print $4}')
MEMORY_USAGE=$(free -h | awk 'NR==2 {print $3"/"$2}')
UPTIME=$(uptime -p)
TEMP=""
if [ -f "/sys/class/thermal/thermal_zone0/temp" ]; then
    TEMP=$(echo "scale=1; $(cat /sys/class/thermal/thermal_zone0/temp) / 1000" | bc)°C
fi

# Check for failed SSH logins
FAILED_SSH=$(grep "Failed password" /var/log/auth.log 2>/dev/null | wc -l)

# Check for banned IPs in fail2ban
BANNED_IPS=0
if command -v fail2ban-client &> /dev/null; then
    BANNED_IPS=$(sudo fail2ban-client status sshd | grep "Total banned" | grep -oE "[0-9]+")
fi

# Create email
{
    echo -e "To: $EMAIL_TO"
    echo -e "Subject: $SUBJECT"
    echo -e "\n$HOSTNAME Weekly Status Report"
    echo -e "============================="
    
    echo -e "\n📊 SYSTEM HEALTH:"
    echo -e "Disk Usage: $DISK_USAGE (Free: $DISK_FREE)"
    echo -e "Memory Usage: $MEMORY_USAGE"
    if [[ ! -z "$TEMP" ]]; then
        echo -e "CPU Temperature: $TEMP"
    fi
    echo -e "System Uptime: $UPTIME"
    
    echo -e "\n🔄 MAINTENANCE STATUS:"
    echo -e "Backup Status: $BACKUP_STATUS"
    echo -e "Update Status: $UPDATE_STATUS"
    
    echo -e "\n🔒 SECURITY STATUS:"
    echo -e "Failed SSH Logins: $FAILED_SSH in the last week"
    echo -e "Banned IPs: $BANNED_IPS"
    
    echo -e "\n🚦 SERVICE STATUS:"
    echo -n "SSH: "; check_service ssh
    
    # Check Pi-hole if installed
    if command -v pihole &> /dev/null; then
        echo -n "Pi-hole: "; check_service pihole-FTL
    fi
    
    # Check Cloudflared if installed
    if systemctl list-unit-files | grep -q cloudflared; then
        echo -n "Cloudflared: "; check_service cloudflared
    fi
    
    # Check Docker if installed
    if command -v docker &> /dev/null; then
        echo -n "Docker: "; check_service docker
        
        if [ "$(check_service docker)" = "✅ Active" ]; then
            echo -e "\n🐳 DOCKER CONTAINERS:"
            docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null || echo "No containers running"
        fi
    fi
    
    # Add Pi-hole specifics if installed
    if command -v pihole &> /dev/null; then
        echo -e "\n🛡️ PI-HOLE STATS:"
        TOTAL_QUERIES=$(pihole -c -j | grep -oP '"dns_queries_today":\s*\K[0-9]+' 2>/dev/null || echo "N/A")
        BLOCKED=$(pihole -c -j | grep -oP '"ads_blocked_today":\s*\K[0-9]+' 2>/dev/null || echo "N/A")
        PERCENT=$(pihole -c -j | grep -oP '"ads_percentage_today":\s*\K[0-9.]+' 2>/dev/null || echo "N/A")
        
        echo -e "Total Queries: $TOTAL_QUERIES"
        echo -e "Blocked: $BLOCKED"
        echo -e "Percentage Blocked: $PERCENT%"
    fi
    
    echo -e "\n📝 SYSTEM NOTES:"
    echo -e "This report was generated on $(date)"
    echo -e "Next scheduled backup: First Sunday of the month at 2 AM"
    echo -e "Next scheduled update: Every Sunday at 2 AM"
    
} > $TEMP_EMAIL

# Send email
if command -v msmtp &> /dev/null; then
    /usr/bin/msmtp --file="${PI_MSMTP_CONFIG}" -a default $EMAIL_TO < $TEMP_EMAIL
else
    # Fallback to mail command
    cat $TEMP_EMAIL | mail -s "$SUBJECT" $EMAIL_TO
fi

# Clean up
rm -f $TEMP_EMAIL

echo "Status report sent to $EMAIL_TO"

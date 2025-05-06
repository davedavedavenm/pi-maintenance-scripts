# Raspberry Pi Maintenance Scripts

A collection of scripts for maintaining and monitoring Raspberry Pi systems and other Linux devices.

## Features

- **Automated System Updates**: Weekly system updates with email notifications
- **System Backup**: Monthly system backup to cloud storage
- **System Status Reports**: Weekly status emails with system health and security information
- **Cleanup Utilities**: Interactive Docker and filesystem cleanup tools
- **Fail2ban Integration**: Security status monitoring

## Scripts

- **update-and-restart.sh**: Performs system updates with error handling and email notifications
- **sd_backup.sh**: Creates and uploads full system backups to cloud storage
- **system_status.sh**: Generates comprehensive system status reports
- **cleanup.sh**: Interactive utility for cleaning Docker resources and filesystem
- **pi_config.sh**: Central configuration file for all scripts

## Requirements

- Raspberry Pi or Linux system
- Required packages: `msmtp`, `rclone`, `fail2ban` (optional)
- For backup: `rsync`, `tar`, `pigz` (optional)

## Setup

1. Clone this repository:
   git clone https://github.com/yourusername/pi-maintenance-scripts.git

2. Configure the settings:
   cd pi-maintenance-scripts
   # Edit the configuration file with your settings
   nano pi_config.sh

3. Add to crontab:
   crontab -e
   
   Add these entries:
   # Weekly system updates (Sunday at 2 AM)
   0 2 * * 0 sudo /home/pi/scripts/update-and-restart.sh
   
   # Monthly backup (First Sunday of each month at 3 AM)
   0 3 * * 0 [ "$(date +\%d)" -le 07 ] && /home/pi/scripts/sd_backup.sh
   
   # Weekly status report (Monday at 8 AM)
   0 8 * * 1 /home/pi/scripts/system_status.sh

## Usage

### System Updates

The system update script runs automatically, but you can also run it manually:

sudo ./update-and-restart.sh

### Backup

Run a backup with:

./sd_backup.sh

Or use dry-run mode to test without making changes:

./sd_backup.sh -d

### System Status

Generate a status report:

./system_status.sh

### Cleanup

Run the interactive cleanup utility:

./cleanup.sh

## Configuration

All scripts use the central configuration file `pi_config.sh`. Edit this file to:

- Set your email address for notifications
- Configure backup paths and remote storage
- Adjust system-specific settings

The scripts automatically detect the hostname and username, making them portable across different systems.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License

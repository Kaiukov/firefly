#!/bin/bash

# Setup script for Firefly III backup cron job
# Run this script once to set up daily backups at 3 AM Kyiv time

set -e

SCRIPT_DIR="$(pwd)"
LOG_FILE="/var/log/firefly-backup.log"

echo "Setting up Firefly III backup cron job..."

# Create log file and set permissions
sudo touch "$LOG_FILE"
sudo chmod 644 "$LOG_FILE"

# Create cron job that runs at 3 AM Kyiv time
# Note: Kyiv time is UTC+2 (winter) or UTC+3 (summer)
# Using 1:00 UTC to cover both scenarios (3 AM in winter, 4 AM in summer DST)
CRON_JOB="0 1 * * * cd $SCRIPT_DIR && ./scripts/backup.sh >> $LOG_FILE 2>&1"

# Add cron job to crontab
echo "Adding cron job for directory: $SCRIPT_DIR"
echo "Cron job: $CRON_JOB"
(crontab -l 2>/dev/null | grep -v "firefly.*backup.sh" || true; echo "$CRON_JOB") | crontab -

echo "Cron job added successfully!"
echo ""
echo "Backup schedule: Daily at 3 AM Kyiv time (1:00 UTC)"
echo "Log file: $LOG_FILE"
echo ""
echo "To view current cron jobs: crontab -l"
echo "To view backup logs: tail -f $LOG_FILE"
echo "To remove cron job: crontab -e (and delete the firefly backup line)"
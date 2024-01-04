#!/bin/bash

# PostgreSQL settings
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD="Timescaledb2023"
export PGPASSWORD
# echo "Password: $PGPASSWORD"

# pg_probackup settings
BACKUP_PATH="/home/ec2-user/ts_backups"
INSTANCE_NAME="timescaledb"

# AWS S3 settings
S3_BUCKET="s3://tsbakups"

# Date and time format for backup naming
DATE_FORMAT=$(date +"%Y%m%d%H%M%S")
# Logging settings
LOG_FILE="$HOME/ts_backup.log"
# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" | tee -a $LOG_FILE
}
# Function to perform a pg_probackup
perform_backup() {
    log_message "Starting backup for instance $INSTANCE_NAME..."
    pg_probackup backup -B $BACKUP_PATH -b DELTA -U $PGUSER -d $DB_NAME --instance $INSTANCE_NAME --stream -h $PGHOST -p $PGPORT --compress --compress-algorithm=zlib --compress-level=5
    log_message "Backup completed."
    log_message "Cleaning old backups on $INSTANCE_NAME..."
    pg_probackup delete -B $BACKUP_PATH --instance $INSTANCE_NAME --delete-wal --retention-redundancy=2 --retention-window=7
    log_message "Cleaning completed..."
}


# Function to upload the backup to S3
upload_to_s3() {
    # Identify the most recent backup directory
    local latest_backup_dir=$(ls -t /home/ec2-user/ts_backups/backups/timescaledb | head -n 1)
    if [ -z "$latest_backup_dir" ]; then
        log_message "No backup directory found."
        return 1
    fi
    local full_backup_path="/home/ec2-user/ts_backups/backups/timescaledb/$latest_backup_dir"

    log_message "Uploading backup $latest_backup_dir to S3..."
    aws s3 cp $full_backup_path $S3_BUCKET/$INSTANCE_NAME/$DATE_FORMAT --recursive
    log_message "Upload to S3 bucket $S3_BUCKET/$INSTANCE_NAME/$DATE_FORMAT completed."
}




# Perform the DELTA backup
perform_backup
if [ $? -ne 0 ]; then
    log_message  "Backup failed"
    exit 1
fi
# Perform upload to S3
upload_to_s3
if [ $? -ne 0 ]; then
    log_message  "Upload to S3 failed"
    exit 1
fi

exit 0

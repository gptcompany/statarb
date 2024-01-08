#!/bin/bash

# PostgreSQL settings
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
#PGPASSWORD=$(grep 'timescaledb_password' /config_cf.yaml | awk '{print $2}' | tr -d '"')
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
export PGPASSWORD

# pg_probackup settings
BACKUP_PATH="/home/ec2-user/ts_backups"
INSTANCE_NAME="timescaledb"

# AWS S3 settings
S3_BUCKET="s3://timescalebackups"

# Logging settings
LOG_FILE="$HOME/ts_backups.log"

# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" | tee -a $LOG_FILE
}

# Function to upload the backup to S3
upload_to_s3() {
    local backup_id_to_upload=$1
    local backup_type=$2  # New argument for backup type
    local backup_path="$BACKUP_PATH/backups/$INSTANCE_NAME/$backup_id_to_upload"
    local backup_date=$(date +"%Y%m%d") # Current date in YYYYMMDD format
    #DEBUG
    # echo "###########$backup_path###########"
    # echo "***********$backup_id_to_upload**************"
    

    if [ ! -d "$backup_path" ]; then
        log_message "Backup directory $backup_path not found." >&2
        return 1
    fi
    # Use backup_type in constructing the S3 upload path or for other purposes
    local s3_upload_path="$S3_BUCKET/$INSTANCE_NAME/$backup_type/$backup_date/$backup_id_to_upload"
    log_message "Uploading backup $backup_id_to_upload to S3..." >&2
    aws s3 cp $backup_path $s3_upload_path --recursive
    log_message "Upload to S3 bucket $s3_upload_path completed." >&2
}


# Function to get the latest FULL backup ID
get_latest_full_backup_id() {
    local last_full_backup
    last_full_backup=$(pg_probackup show -B $BACKUP_PATH --instance $INSTANCE_NAME | grep ' FULL ' | grep -v 'ERROR' | tail -1)
    if [ -z "$last_full_backup" ]; then
    # nothing is echoed to standard output
        echo ""
    else
        local latest_full_backup_id=$(echo "$last_full_backup" | awk '{print $3}')
        # Only the latest_full_backup_id is echoed to standard output
        echo "$latest_full_backup_id"
    fi
}

# Function to perform a pg_probackup and capture backup ID
perform_backup() {
    local backup_mode=$1 # FULL or DELTA
    
    local backup_output
    log_message "Starting $backup_mode backup for instance $INSTANCE_NAME..." >&2  # Redirect to standard error
    
    backup_output=$(pg_probackup backup -B $BACKUP_PATH -b $backup_mode -U $PGUSER -d $DB_NAME --instance $INSTANCE_NAME --stream -h $PGHOST -p $PGPORT --compress --compress-algorithm=zlib --compress-level=5 2>&1)
    echo "$backup_output" >&2 # Redirect to standard error
    if [ $? -ne 0 ]; then
        log_message "Backup operation failed." >&2  # Redirect to standard error
        return 1
    fi
    
    local backup_id_from_info=$(echo "$backup_output" | grep -oP 'INFO: Backup \K\S+(?= completed)')
    local backup_id_from_id=$(echo "$backup_output" | grep -oP 'backup ID: \K\S+(?=,)')

    # Debug messages redirected to standard error
    #echo "check $backup_id_from_info *** check $backup_id_from_id ***" >&2

    if [ -z "$backup_id_from_info" ] || [ -z "$backup_id_from_id" ]; then
        log_message "Failed to capture backup ID." >&2  # Redirect to standard error
        return 1
    fi

    if [ "$backup_id_from_info" != "$backup_id_from_id" ]; then
        log_message "Mismatch in captured backup IDs: $backup_id_from_info and $backup_id_from_id." >&2  # Redirect to standard error
        return 1
    else
        local backup_id=$backup_id_from_info
    fi

    # Only the backup_id is echoed to standard output
    echo "$backup_id"
}


# Function to check for a specific backup in S3
check_backup_in_s3() {
    local backup_id=$1
    log_message "Checking for backup $backup_id in S3..."

    if aws s3 ls "$S3_BUCKET/$INSTANCE_NAME/$backup_id"; then
        log_message "Backup $backup_id found in S3."
        return 0
    else
        log_message "No backup $backup_id found in S3."
        return 1
    fi
}

# Decide whether to perform a Full or Delta backup
perform_required_backup() {
    local latest_full_backup_id=$(get_latest_full_backup_id)

    if [ -n "$latest_full_backup_id" ]; then
        if check_backup_in_s3 "$latest_full_backup_id"; then
            local delta_backup_id=$(perform_backup DELTA)
            if [ -n "$delta_backup_id" ]; then
            #DEBUG
            log_message "Delta id: $delta_backup_id" >&2
                upload_to_s3 "$delta_backup_id" "$backup_type"
            else
                log_message "Delta backup failed or no new backup was created."
            fi
        else
            log_message "Latest full id: $latest_full_backup_id" >&2
            upload_to_s3 "$latest_full_backup_id" "$backup_type"
        fi
    else
        local full_backup_id=$(perform_backup FULL)
        if [ -n "$full_backup_id" ]; then
            upload_to_s3 "$full_backup_id"
        else
            log_message "Full backup failed or no new full backup was created." >&2
        fi
    fi
}


# Execute the backup decision logic
perform_required_backup

exit 0
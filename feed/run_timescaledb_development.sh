#!/bin/bash
# DEVELOPMENT Environment Setup Script for PostgreSQL with TimescaleDB on local pc instance
# chmod +x /home/ec2-user/statarb/feed/run_timescaledb.sh
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
#PGPASSWORD=$(grep 'timescaledb_password' /config_cf.yaml | awk '{print $2}' | tr -d '"')
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
export PGUSER PGHOST PGPORT PGPASSWORD
CONTAINER_NAME="timescaledb"
PROD_DB_HOST="57.181.106.64"  # Production Database IP
# AWS S3 settings
S3_BUCKET="s3://timescalebackups"
# Logging settings
HOME="/home/sam"
LOG_FILE="$HOME/ts_replica.log"
IP_FILE="ip_development.txt"
IP_FILE_FOLDER="/home/sam/ip_address/"
REPLICATION_SLOT="timescale"
# Function to log messages
exec 3>>$LOG_FILE
# Function to log messages and command output to the log file
log_message() {
    local message="$(date +"%Y-%m-%d %T"): $1"
    echo "$message" >&3  # Log to the log file via fd3
    echo "$message" >&2  # Display on the screen (stderr)
    if [ -n "$2" ]; then
        echo "$2" >&3   # Log stdout to the log file via fd3
        echo "$2" >&2   # Display stdout on the screen (stderr)
    fi
    if [ -n "$3" ]; then
        echo "$3" >&3   # Log stderr to the log file via fd3
        echo "$3" >&2   # Display stderr on the screen (stderr)
    fi
}
# Improved error handling within functions
handle_error() {
    local error_message=$1
    log_message "Error: $error_message"
    # Exit the script or perform any necessary cleanup
    exit 1
}
# Enhanced function to check Docker container status
check_container_status() {
    local container_name=$1
    local status=$(docker inspect --format="{{.State.Running}}" $container_name 2>/dev/null)

    if [ $? -eq 1 ]; then
        log_message "Container $container_name does not exist."
        return 1
    elif [ "$status" == "false" ]; then
        log_message "Container $container_name is not running."
        return 2
    else
        log_message "Container $container_name is running."
        return 0
    fi
}
# Modified retry_command function to handle different types of commands including functions
retry_command() {
    local cmd="$1"
    local max_attempts="$2"
    shift 2
    local args=("$@") # Remaining arguments
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_message "Attempting command: $cmd ${args[*]} (Attempt $attempt)"
        eval "$cmd ${args[*]}" && sleep 3 && return 0  # Command or function succeeded, exit loop
        log_message "Command failed (Attempt $attempt). Retrying..."
        ((attempt++))
        sleep 5  # Adjust sleep duration between retries
    done

    log_message "Max attempts reached. Command failed."
    handle_error "Command failed after $max_attempts attempts: $cmd"
}

# Starting the TimescaleDB Docker container

start_container(){
    # First, check the status of the container
    check_container_status $CONTAINER_NAME
    local container_status=$?

    if [ $container_status -eq 0 ]; then
        log_message "Container $CONTAINER_NAME is already running."
    elif [ $container_status -eq 1 ]; then
        # Container does not exist, need to create and start it
        log_message "Container $CONTAINER_NAME does not exist. Creating and starting container."
        mkdir -p ~/timescaledb_data
        docker run -d \
        --name $CONTAINER_NAME \
        --restart "always" \
        -e PGDATA=/var/lib/postgresql/data \
        -e POSTGRES_USER="$PGUSER" \
        -e POSTGRES_PASSWORD="$PGPASSWORD" \
        -e POSTGRES_LOG_MIN_DURATION_STATEMENT=1000 \
        -e POSTGRES_LOG_ERROR_VERBOSITY=default \
        -p $PGPORT:$PGPORT \
        -v /home/sam/timescaledb_data:/var/lib/postgresql/data:z \
        timescale/timescaledb:latest-pg14

        # Check if the container started correctly
        if [ $? -eq 0 ]; then
            log_message "Container $CONTAINER_NAME started successfully."
            # Wait a bit for the container to initialize
            sleep 10
            # Additional check to confirm the container is running after initialization
            check_container_status $CONTAINER_NAME
            if [ $? -ne 0 ]; then
                log_message "Error: Container $CONTAINER_NAME failed to start."
                handle_error "Container failed to start"
            fi
        else
            log_message "Error: Failed to start container $CONTAINER_NAME."
            handle_error "Failed to start container"
        fi
    elif [ $container_status -eq 2 ]; then
        log_message "Container $CONTAINER_NAME exists but is not running. Starting container."
        docker start $CONTAINER_NAME
        if [ $? -ne 0 ]; then
            log_message "Error: Failed to start existing container $CONTAINER_NAME."
            handle_error "Failed to start existing container"
        fi
    fi
}
# Function to initialize data for replication
initialize_replication_data() {
    log_message "Initializing replication data from production server..."
    pg_basebackup -h $PROD_DB_HOST -D ~/timescaledb_data -U $PGUSER -v -P -X stream --write-recovery-conf -S $REPLICATION_SLOT
    if [ $? -eq 0 ]; then
        log_message "Replication data initialized successfully."
    else
        log_message "Error: Failed to initialize replication data."
        handle_error "Failed to initialize replication data"
    fi
}
install_aws_cli() {
    log_message "Checking for AWS CLI installation..."
    if ! command -v aws &> /dev/null; then
        log_message "AWS CLI not found. Starting installation..."

        # Assuming a Debian/Ubuntu-based system. Modify as needed for other distributions.
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
        if command -v aws &> /dev/null; then
            log_message "AWS CLI successfully installed."
        else
            handle_error "AWS CLI installation failed."
        fi
    else
        log_message "AWS CLI is already installed."
    fi
}
upload_to_s3() {
    local file_to_upload="${IP_FILE_FOLDER}${IP_FILE}"  # Corrected line

    # Ensure AWS CLI is installed
    install_aws_cli

    # Check if the file exists
    if [ ! -f "$file_to_upload" ]; then
        log_message "File to upload does not exist: $file_to_upload"
        return 1
    fi

    # Upload to S3
    if aws s3 cp "$file_to_upload" "$S3_BUCKET/"
    then
        log_message "Successfully uploaded $file_to_upload to S3 bucket $S3_BUCKET"
    else
        log_message "Failed to upload $file_to_upload to S3"
        return 1
    fi
}
get_public_ip() {
    # Primary service to fetch the public IP address
    public_ip=$(curl -s https://ipinfo.io/ip)

    # Check if the IP address is valid; if not, try a secondary service
    if ! [[ $public_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $public_ip =~ ^[0-9a-fA-F:]+$ ]]; then
        log_message "Primary IP service failed. Trying secondary service..."
        public_ip=$(curl -s https://ifconfig.me)
    fi

    # Final check if the IP address is valid
    if [[ $public_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $public_ip =~ ^[0-9a-fA-F:]+$ ]]; then
        local ip_file_dir="$IP_FILE_FOLDER"
        mkdir -p "$ip_file_dir"
        local ip_file_path="${ip_file_dir}$IP_FILE"

        echo "$public_ip" > "$ip_file_path"  # Corrected line
        log_message "Public IP address: $public_ip"
        log_message "Public IP address saved to $ip_file_path"
    else
        handle_error "Failed to retrieve a valid public IP address."
    fi
}
# Main script execution
retry_command get_public_ip 2
retry_command upload_to_s3 2
retry_command start_container 3
retry_command initialize_replication_data 1
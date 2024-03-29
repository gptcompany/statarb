#!/bin/bash
TIMESCALEDB_IP="57.181.106.64"
STANDBY_IP="timescaledb.mywire.org"
CLUSTER_CONTROL_IP="43.207.147.235"
# User to SSH into TimescaleDB server user postgres
SSH_USER_POSTGRES="postgres"
# Command to get the IP of the current server
LOCAL_IP=$(hostname -I | awk '{print $1}')
# Function to generate and display SSH key
generate_and_cat_ssh_key() {
    local user=$1
    local ssh_dir

    if [ "$user" = "postgres" ]; then
        ssh_dir="/var/lib/postgresql/.ssh"
    elif [ "$user" = "barman" ]; then
        # Get the home directory of the barman user
        ssh_dir="$(getent passwd barman | cut -d: -f6)/.ssh"
    else
        ssh_dir="$(eval echo ~$user)/.ssh"
    fi

    sudo mkdir -p $ssh_dir
    sudo chown $user:$user $ssh_dir
    sudo chmod 700 $ssh_dir
    local ssh_key="$ssh_dir/id_rsa"

    if [ ! -f $ssh_key ]; then
        sudo -u $user ssh-keygen -t rsa -f $ssh_key -N ''
    fi

    echo ">>>>Displaying public SSH key for user: $user"
    sudo -u $user cat $ssh_key.pub
    echo "End of public SSH key for user: $user <<<<<<<"
}


install_dependencies() {
    if command -v apt-get &>/dev/null; then
        # Debian, Ubuntu, or other apt-based systems
        # Check if AWS CLI is installed and its version
        if aws --version &>/dev/null; then
            echo "AWS CLI is already installed."
            CURRENT_VERSION=$(aws --version | cut -d/ -f2 | cut -d' ' -f1)
            REQUIRED_VERSION="2.0.0"  # Set your required minimum version here
            if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
                echo "Upgrading AWS CLI..."
                # Commands to upgrade AWS CLI
                curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
                unzip -o awscliv2.zip
                sudo ./aws/install --update
            else
                echo "AWS CLI is up to date."
            fi
        else
            echo "AWS CLI is not installed. Installing now..."
            # Commands to install AWS CLI
            curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
            unzip -o awscliv2.zip
            sudo ./aws/install
        fi

        # Check if AWS is configured
        if aws configure list; then
            echo "AWS is configured."
        else
            echo "AWS is not configured."
            sudo aws configure
        fi
        sudo apt-get update && sudo apt-get upgrade -y
        sudo apt-get install build-essential libpq-dev python3-dev curl wget rsync software-properties-common postgresql-contrib -y
    else
        echo "Package manager not supported. Install the packages manually."
    fi
}

# Main 
sudo chmod +x $HOME/statarb/scripts/install_terminal_ubuntu.sh
$HOME/statarb/scripts/install_terminal_ubuntu.sh
install_dependencies
# Generate and display SSH key for postgres
generate_and_cat_ssh_key "postgres"
# Generate and display SSH key for barman
#generate_and_cat_ssh_key "barman"
# Generate and display SSH key for barman
generate_and_cat_ssh_key "ubuntu"
echo "copy the ssh key in sudo nano ~/.ssh/authorized_keys or sudo vi ~/.ssh/authorized_keys on the machine you want SSH into (main and standby for all users you want connect (ubuntu, ec2-user, postgres))"
# wait for user to confirm that authorized_key are saved before continuing with the script
read -p "Press Enter once the SSH key is saved in authorized_keys..."
read -p "Press Enter once again..."
# Test SSH connection
echo "Testing SSH connection to $CLUSTER_CONTROL_IP..."
ssh -o BatchMode=yes -o ConnectTimeout=5 barman@${CLUSTER_CONTROL_IP} "echo 'SSH connection successful'"
if [ $? -ne 0 ]; then
    echo "SSH connection failed. Please check your settings."
    read -p "Press Enter once the SSH key is saved in authorized_keys..."
fi

REMOTE_KEY=$(ssh barman@${CLUSTER_CONTROL_IP} "cat ~/.ssh/id_rsa.pub")
# On the local machine, append the key to authorized_keys
echo "$REMOTE_KEY" >> ~/.ssh/authorized_keys
chmod 600 $HOME/.ssh/authorized_keys
sudo su - ubuntu







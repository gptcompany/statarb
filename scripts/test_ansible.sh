#!/bin/bash

# Check for the correct number of arguments
# if [ "$#" -ne 1 ]; then
#     echo "Usage: $0 TIMESCALEDB_PRIVATE_IP"
#     exit 1
# fi

# Assign arguments to variables
TIMESCALEDB_PRIVATE_IP="172.31.35.73"
TIMESCALEDB_PUBLIC_IP="57.181.106.64"
CLUSTERCONTROL_PRIVATE_IP="172.31.32.75"
CLUSTERCONTROL_PUBLIC_IP="43.207.147.235"
STANDBY_PUBLIC_IP="timescaledb.mywire.org"
ECS_INSTANCE_PRIVATE_IP="172.31.38.68"
ECS_INSTANCE_PUBLIC_IP="52.193.34.34"
AWS_SECRET_ID="ultimaec2key"

# Check if Ansible is installed, install if not
if ! command -v ansible > /dev/null; then
    echo "Ansible not found. Installing Ansible..."
    sudo apt-get update
    sudo apt-get install -y ansible
else
    echo "Ansible is already installed."
fi

# Fetch secret from AWS Secrets Manager
if command -v aws > /dev/null; then
    echo "Fetching SSH key from AWS Secrets Manager..."
    aws secretsmanager get-secret-value --secret-id $AWS_SECRET_ID --query 'SecretString' --output text | base64 --decode > $HOME/retrieved_key.pem
    chmod 600 $HOME/retrieved_key.pem
else
    echo "AWS CLI not found. Please install AWS CLI and configure it."
    exit 1
fi
# Generate Ansible playbook for installing acl
cat <<EOF > $HOME/install_acl.yml
---
- name: Install ACL on target machines
  hosts: all
  become: yes
  tasks:
    - name: Ensure ACL is installed
      apt:
        name: acl
        state: present
EOF

# Generate Ansible playbook for configuring barman
cat <<EOF > $HOME/configure_barman_on_cc.yml
---
- name: Setup Barman for TimescaleDB Backup
  hosts: localhost
  become: yes
  vars:
    timescaledb_PRIVATE_ip: "$TIMESCALEDB_PRIVATE_IP"

  tasks:
    - name: Check if barman user exists
      command: id barman
      register: barman_user
      ignore_errors: yes

    - name: Install barman
      apt:
        name: barman
        state: present
      when: barman_user.rc != 0

    - name: Ensure barman user exists
      user:
        name: barman
        system: yes
        create_home: yes
      when: barman_user.rc != 0

    - name: Check for existing SSH public key for barman user
      stat:
        path: "/home/barman/.ssh/id_rsa.pub"
      register: ssh_key_stat

    - name: Ensure .ssh directory exists for barman user
      file:
        path: "/home/barman/.ssh"
        state: directory
        owner: barman
        group: barman
        mode: '0700'
      when: barman_user.rc != 0

    - name: Generate SSH key for barman user if not exists
      user:
        name: barman
        generate_ssh_key: yes
        ssh_key_file: "/home/barman/.ssh/id_rsa"
      when: ssh_key_stat.stat.exists == false and barman_user.rc != 0

    - name: Ensure barman and ubuntu have no password in sudoers
      lineinfile:
        path: /etc/sudoers
        line: "{{ item }}"
        validate: '/usr/sbin/visudo -cf %s'
      loop:
        - 'barman ALL=(ALL) NOPASSWD: ALL'
        - 'ubuntu ALL=(ALL) NOPASSWD: ALL'
EOF

# Create the playbook to modify sudoers
cat <<EOF > $HOME/modify_sudoers.yml
---
- name: Update sudoers for ubuntu and postgres users
  hosts: all
  gather_facts: no
  become: yes
  tasks:
    - name: Ensure ubuntu user can run all commands without a password
      lineinfile:
        path: /etc/sudoers.d/ubuntu
        line: 'ubuntu ALL=(ALL) NOPASSWD: ALL'
        create: yes
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
    - name: Ensure postgres user has necessary sudo privileges
      lineinfile:
        path: /etc/sudoers.d/postgres
        line: 'postgres ALL=(ALL) NOPASSWD: ALL'
        create: yes
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
EOF

# Create the playbook for SSH setup
cat <<EOF > $HOME/configure_ssh_from_cc.yml
---
- name: Setup SSH Key for ubuntu User Locally and Authorize on Servers
  hosts: localhost
  gather_facts: no
  tasks:
    - name: Check if SSH public key exists for ubuntu user
      stat:
        path: "{{ lookup('env', 'HOME') }}/.ssh/id_rsa.pub"
      register: ssh_pub_key
    - name: Generate SSH key for ubuntu user if not exists
      user:
        name: ubuntu
        generate_ssh_key: yes
        ssh_key_file: "{{ lookup('env', 'HOME') }}/.ssh/id_rsa"
      when: ssh_pub_key.stat.exists == false

- name: Setup SSH Access for ubuntu User on TimescaleDB Servers
  hosts: timescaledb_servers
  gather_facts: no
  vars:
    ansible_user: ubuntu
    ansible_ssh_private_key_file: "{{ lookup('env','HOME') }}/retrieved_key.pem"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
  tasks:
    - name: Fetch the public key of ubuntu user
      slurp:
        src: "{{ lookup('env','HOME') }}/.ssh/id_rsa.pub"
      register: ubuntu_ssh_pub_key
      delegate_to: localhost

    - name: Ensure ubuntu user can SSH into each server without a password
      authorized_key:
        user: ubuntu
        state: present
        key: "{{ ubuntu_ssh_pub_key.content | b64decode }}"

- name: Ensure SSH public key is readable by all
  file:
    path: /var/lib/barman/.ssh/id_rsa.pub
    mode: '0644'
  become: yes
  become_user: root

- name: Slurp Barman's SSH public key
  ansible.builtin.slurp:
    src: "{{ lookup('env','HOME') }}/.ssh/id_rsa.pub"
  register: barman_ssh_key_slurped

- name: Decode and store Barman's SSH public key
  set_fact:
    barman_ssh_key: "{{ barman_ssh_key_slurped['content'] | b64decode }}"


- name: Authorize Barman's SSH Key for Postgres User on Remote Servers
  hosts: timescaledb_servers
  gather_facts: no
  vars:
    ansible_user: ubuntu
    ansible_ssh_private_key_file: "{{ lookup('env','HOME') }}/retrieved_key.pem"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
  tasks:
    - name: "Ensure Postgres user can SSH into each server without a password"
      authorized_key:
        user: postgres
        key: "{{ barman_ssh_key }}"
        state: present


EOF

# Generate the Ansible inventory
cat <<EOF > $HOME/timescaledb_inventory.yml
---
all:
  vars:
    ansible_user: ubuntu
    ansible_ssh_private_key_file: "{{ lookup('env', 'HOME') }}/retrieved_key.pem"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
  children:
    timescaledb_servers:
      hosts:
        $STANDBY_PUBLIC_IP: {}
        $TIMESCALEDB_PRIVATE_IP: {}
EOF

echo "Playbooks created. Proceed with running Ansible playbooks as needed."

# Execute playbooks
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/install_acl.yml
ansible-playbook $HOME/configure_barman_on_cc.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/modify_sudoers.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/configure_ssh_from_cc.yml

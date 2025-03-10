#!/bin/bash

function amIRoot() {
  if [ "$EUID" -ne 0 ]; then
    echo "$(getDate) ❌ Please run this script using sudo."
    exit 1
  fi
}

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function installLogrotator() {
  containers=$(docker ps --format '{{.ID}}')
  container_ids=$(docker inspect --format '{{.Id}}' $containers)

  for container_id in $container_ids; do
    echo "$(getDate) 🔄 Create logrotate file for container: $container_id"
    
    cat << EOF > ~/docker_$container_id
/var/lib/docker/containers/$container_id/$container_id-json.log {
    rotate 14
    olddir /var/lib/docker/containers/$container_id/$container_id-json.log-old
    daily
    missingok
    #notifempty
    nocreate
    copytruncate
    compress
    compresscmd /usr/bin/zstd
    compressoptions -7T0
    createolddir 750 root root
    delaycompress
    dateext
    dateformat -%Y%m%d-%H%M%S
}

EOF

    sudo chown root: ~/docker_$container_id
    sudo chmod 644 ~/docker_$container_id
    sudo mv ~/docker_$container_id /etc/logrotate.d/docker_$container_id

    echo "$(getDate) ✅ Create the logrotate file: /etc/logrotate.d/docker_$container_id"
  done

}

function main() {
  amIRoot

  logrotate --version > /dev/null 2>&1 && {
    echo "$(getDate) ✅ logrotate is already installed"
  } || {
    echo "$(getDate) 🔴 Logrotate is not available. Please install it first to use this utility"
    exit 1
  }

  if zstd --version > /dev/null 2>&1; then
    echo "$(getDate) ✅ zstd is already installed"
    installLogrotator
  else
    echo "$(getDate) 📦 Install zstd"
    sudo apt install zstd -y && {
      echo "$(getDate) ✅ zstd is installed"
      installLogrotator
    } || {
      echo "$(getDate) 🔴 Failed to install zstd"
      exit 1
    }
  fi
}

main

#!/bin/bash

CURRENT_DIRNAME=$(dirname "$(readlink -f "$0")")
cd "$CURRENT_DIRNAME/.." || { echo "🔴 Can't change directory to $CURRENT_DIRNAME/.."; exit 1; }
PATH_TO_ODOO="$(pwd)"
SERVICE_NAME=$(basename "$(pwd)")

DOCKER_COMPOSE_FILE="docker-compose.yml"
GIT_PATH="./git"

function isDirectoryGitRepository() {
  dir=$1

  if [ -d "$dir/.git" ]; then
    if git rev-parse --is-inside-work-tree &>/dev/null; then
      return 0
    else
      return 1
    fi
  else
    return 1
  fi  
}

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function getSubDirectories() {
  dir=$1
  subdirs="$(ls -d "$dir"/*/)"
  echo "$subdirs"
}

function main() {
  echo "$(getDate) Change Directory to $PATH_TO_ODOO"
  cd "$PATH_TO_ODOO" || { echo "🔴 Can't change directory to $PATH_TO_ODOO"; exit 1; }

  echo "$(getDate) 🔵 Start checking git repositories"
  GIT_SUBDIRS=$(getSubDirectories "$GIT_PATH")
  
  pulledrepositories=0
  for subdir in $GIT_SUBDIRS; do
    if isDirectoryGitRepository "$subdir"; then
      echo "$(getDate) 🟦 Fetch and pull $subdir"
      git -C "$subdir" fetch
      if git -C "$subdir" pull | grep -v "up to date" ;then
        pulledrepositories=$((pulledrepositories+1))
      fi
    else
      echo "$(getDate) 🔴 $subdir is not a git repository."
      echo "$(getDate) 🔴 Please make sure you have added $subdir directory to your snapshot script to backup the addons manually."
    fi
  done

  if [ $pulledrepositories -gt 0 ]; then
    echo "$(getDate) 🟦 Rebuilding the docker containers"
    docker compose -f $PATH_TO_ODOO/$DOCKER_COMPOSE_FILE up -d --build
  else
    echo "$(getDate) ✅ No updates found"
  fi

  echo "$(getDate) ✅ Finish checking updates for $SERVICE_NAME"
}

main

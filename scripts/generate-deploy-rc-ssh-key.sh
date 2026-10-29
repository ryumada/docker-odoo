#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Generates ed25519 SSH key pair for cross-VPS deploy_release_candidate and displays authorization snippet.
# Usage: ./scripts/generate-deploy-rc-ssh-key.sh [--target-host HOST] [--target-user USER] [--admin-user ADMIN] [--port PORT] [--from IP|--no-from] [--force]
# Dependencies: ssh-keygen, git, sudo, ssh, base64

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
exec "$CURRENT_DIR/generate-snapshot-ssh-key.sh" --tool deploy_rc "$@"

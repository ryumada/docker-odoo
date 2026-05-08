#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Detects the host OS family and sets OS_FAMILY and PKG_MANAGER variables.
# Usage: source ./scripts/lib/os_detect.sh
# Dependencies: bash, /etc/os-release

# --- OS Detection ---
# Exports:
#   OS_FAMILY   = "debian" | "rhel" | "unknown"
#   PKG_MANAGER = "apt"    | "dnf"  | "unknown"

detect_os_family() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "$ID" in
      debian|ubuntu|linuxmint|pop)
        OS_FAMILY="debian"
        PKG_MANAGER="apt"
        ;;
      centos|rhel|almalinux|rocky|fedora)
        OS_FAMILY="rhel"
        # Prefer dnf over yum on CentOS 8+ / RHEL 8+
        if command -v dnf &>/dev/null; then
          PKG_MANAGER="dnf"
        else
          PKG_MANAGER="yum"
        fi
        ;;
      *)
        OS_FAMILY="unknown"
        PKG_MANAGER="unknown"
        ;;
    esac
  else
    OS_FAMILY="unknown"
    PKG_MANAGER="unknown"
  fi

  export OS_FAMILY
  export PKG_MANAGER
}

detect_os_family

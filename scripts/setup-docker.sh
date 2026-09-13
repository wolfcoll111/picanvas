#!/usr/bin/env bash
# PiCanvas — ensure Docker Engine + Compose plugin are installed and running.
# Idempotent: safe to re-run. Supports Raspberry Pi OS / Debian / Ubuntu (ARM64/x86_64).
set -euo pipefail

SUDO=""
[[ "${EUID:-$(id -u)}" -ne 0 ]] && SUDO="sudo"
RUN_AS="${SUDO_USER:-${USER:-$(id -un)}}"

green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|armv7l|x86_64) ;;
  *) warn "Untested CPU architecture '$ARCH' — install will continue but images may not exist." ;;
esac

# Recover from a previously killed run (e.g. terminal closed mid-install):
# wait for a stale package-manager lock, then finish interrupted configures.
if command -v fuser >/dev/null 2>&1; then
  for i in 1 2 3 4 5 6; do
    if $SUDO fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
      echo "[docker] Another installer holds the package lock — waiting 20s ($i/6) ..."
      sleep 20
    else
      break
    fi
  done
fi
$SUDO dpkg --configure -a >/dev/null 2>&1 || true

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  green "[docker] $(docker --version) + $(docker compose version --short) already installed."
else
  green "[docker] Installing Docker Engine + Compose plugin via get.docker.com ..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  $SUDO sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi

# Enable + start the daemon (systemd, falling back to service/init where needed).
if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || $SUDO systemctl start docker || true
elif command -v service >/dev/null 2>&1; then
  $SUDO service docker start || true
fi

# Let the invoking (non-root) user run docker without sudo after next login.
if [[ "$RUN_AS" != "root" ]]; then
  if ! id -nG "$RUN_AS" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    $SUDO usermod -aG docker "$RUN_AS"
    warn "[docker] Added '$RUN_AS' to the docker group — log out/in for passwordless docker. Continuing with elevated rights for now."
  fi
fi

docker --version
docker compose version
$SUDO docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon is not responding. Reboot and re-run ./install.sh." >&2; exit 1; }
green "[docker] Engine + Compose ready."

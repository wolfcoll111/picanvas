#!/usr/bin/env bash
# PiCanvas — Tailscale pre-flight: TUN device + persistent state directory.
# The sidecar itself is started by `docker compose --profile tailscale up -d`.
# No-op (success) when USE_TAILSCALE is not true.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/config.env" ]] && { set -a; source "$REPO_DIR/config.env"; set +a; }

SUDO=""
[[ "${EUID:-$(id -u)}" -ne 0 ]] && SUDO="sudo"

green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }

[[ "${USE_TAILSCALE:-false}" == "true" ]] || { echo "[tailscale] Disabled (USE_TAILSCALE != true) — skipping."; exit 0; }

# 1. TUN device required for any WireGuard-based networking.
if [[ ! -c /dev/net/tun ]]; then
  green "[tailscale] Creating /dev/net/tun ..."
  $SUDO mkdir -p /dev/net
  $SUDO mknod /dev/net/tun c 10 200 2>/dev/null || true
  $SUDO chmod 600 /dev/net/tun || true
  $SUDO modprobe tun 2>/dev/null || warn "[tailscale] Could not load kernel module 'tun' — enable it for your kernel/board."
fi
[[ -c /dev/net/tun ]] || { echo "ERROR: /dev/net/tun unavailable — Tailscale cannot run on this kernel." >&2; exit 1; }

# 2. Persistent state so the tailnet identity survives restarts/reinstalls.
mkdir -p "$REPO_DIR/data/tailscale"
if [[ -n "${SUDO_USER:-}" ]]; then
  $SUDO chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$REPO_DIR/data/tailscale" || true
fi

# 3. Auth-key sanity hint (non-fatal: manual `tailscale up` remains possible).
if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
  warn "[tailscale] No TAILSCALE_AUTHKEY set — after startup run: docker exec picanvas-tailscale tailscale up"
else
  green "[tailscale] Auth key present — sidecar will join as '${TS_HOSTNAME:-picanvas}' automatically."
fi
green "[tailscale] Pre-flight OK."

#!/usr/bin/env bash
# PiCanvas installer — one-command headless web workstation for Raspberry Pi.
# Usage:
#   ./install.sh                    # interactive setup (menus)
#   ./install.sh --non-interactive  # headless: uses values already in config.env
#   curl -fsSL <tarball-url> | tar -xz && cd picanvas-main && ./install.sh
set -euo pipefail

VERSION="1.0.4"
REPO_URL="https://github.com/wolfcoll111/picanvas.git"
TARBALL_URL="https://github.com/wolfcoll111/picanvas/archive/refs/heads/main.tar.gz"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$REPO_DIR/config.env"
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
NON_INTERACTIVE=false
[[ "${1:-}" == "--non-interactive" || "${1:-}" == "-y" ]] && NON_INTERACTIVE=true

# --- 0. Self-bootstrap (curl-pipe support) ---------------------------------
# If fetched standalone (no compose file beside it), fetch the full repo first.
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[PiCanvas] Full repo not found — bootstrapping into ./picanvas ..."
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 "$REPO_URL" ./picanvas
  else
    mkdir -p ./picanvas
    curl -fsSL "$TARBALL_URL" | tar -xz -C ./picanvas --strip-components=1
  fi
  exec bash ./picanvas/install.sh "$@"
fi
cd "$REPO_DIR"

# --- 1. Privilege check -----------------------------------------------------
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: run as root or install sudo first." >&2
    exit 1
  fi
  if ! sudo -n true 2>/dev/null; then
    echo "[PiCanvas] Administrator privileges are required (Docker install, TUN device)."
    sudo -v || { echo "ERROR: sudo authentication failed." >&2; exit 1; }
  fi
  SUDO="sudo"
fi
RUN_AS="${SUDO_USER:-${USER:-$(id -un)}}"

# --- helpers ----------------------------------------------------------------
HAS_WHIPTAIL=false
command -v whiptail >/dev/null 2>&1 && HAS_WHIPTAIL=true

green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
cyan()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die()   { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- live progress (so a quiet Pi never looks frozen) -------------------------
# Usage: step_begin "label" ... step_done "label"
# Prints Step N/7 + percent, with a heartbeat line every 20s during long steps.
STEP_TOTAL=7
STEP_CUR=0
TICKER_PID=""
TICKER_START=0
bar() {
  local pct="$1" width=24 filled empty
  filled=$(( pct * width / 100 )); empty=$(( width - filled ))
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
}
show_pct() { printf '[PiCanvas] [%s] %3s%% — %s\n' "$(bar "$1")" "$1" "$2"; }
step_begin() {
  # $1=label, $2=optional "noticker" (for interactive whiptail steps — the
  # menus themselves prove we're alive, and a background line would glitch them)
  STEP_CUR=$(( STEP_CUR + 1 ))
  echo ""
  show_pct "$(( (STEP_CUR - 1) * 100 / STEP_TOTAL ))" "Step $STEP_CUR/$STEP_TOTAL: $1 ..."
  if [[ "${2:-}" == "noticker" ]]; then TICKER_PID=""; return; fi
  TICKER_START=$(date +%s)
  (
    while true; do
      sleep 20
      el=$(( $(date +%s) - TICKER_START ))
      printf '[PiCanvas] ... still working: %s (%ss elapsed — not frozen, Pi steps go quiet) ...\n' "$1" "$el" >&2
    done
  ) &
  TICKER_PID=$!
}
step_done() {
  if [[ -n "$TICKER_PID" ]]; then kill "$TICKER_PID" 2>/dev/null || true; wait "$TICKER_PID" 2>/dev/null || true; TICKER_PID=""; fi
  show_pct "$(( STEP_CUR * 100 / STEP_TOTAL ))" "Step $STEP_CUR/$STEP_TOTAL: $1 — done"
}
trap '[[ -n "${TICKER_PID:-}" ]] && kill "$TICKER_PID" 2>/dev/null || true' EXIT

# Map legacy/alias flavor names to real linuxserver/webtop tags.
normalise_flavor() {
  case "$1" in
    xfce|ubuntu|ubuntu-xfce) echo "ubuntu-xfce" ;;
    alpine|alpine-desktop|alpine-xfce) echo "alpine-xfce" ;;
    arch|arch-xfce) echo "arch-xfce" ;;
    fedora|fedora-xfce) echo "fedora-xfce" ;;
    *) echo "$1" ;;
  esac
}

# Stale keypresses left over from a previous prompt can make the next dialog
# swallow an Enter (looks like "I pressed Enter and nothing happened").
# Drain them before each dialog. NOTE: never print or clear the screen here —
# anything written to stdout/stderr inside a $(...) capture leaks into the
# captured answer (this broke port prompts on kitty TERM as
# "Invalid port ''xterm-kitty': unknown terminal type.\n3000'").
drain_stdin() {
  local flags
  flags=$(stty -g 2>/dev/null) || return 0
  stty -icanon -echo min 0 time 0 2>/dev/null || return 0
  # shellcheck disable=SC2162
  while read -r -t 0.05 _junk 2>/dev/null; do :; done || true
  stty "$flags" 2>/dev/null || true
}
wt() { drain_stdin; whiptail "$@" 3>&1 1>&2 2>&3; }

ask_choice_flavor() {
  local def="${1:-ubuntu-xfce}" choice=""
  if $HAS_WHIPTAIL && ! $NON_INTERACTIVE; then
    choice=$(wt --title "PiCanvas $VERSION — Desktop (Step 2 of 6)" --menu \
      "Pick a desktop image (lighter = less RAM, fewer preinstalled apps). ENTER = confirm highlighted choice:" 17 70 4 \
      "ubuntu-xfce" "Standard — Ubuntu + XFCE (recommended)" \
      "alpine-xfce" "Ultra-light — Alpine + XFCE (~200MB RAM)" \
      "arch-xfce" "Bleeding-edge — Arch + XFCE" \
      "fedora-xfce" "Alternative — Fedora + XFCE") \
      || die "Setup cancelled. Press ENTER — nothing further runs."
  elif ! $NON_INTERACTIVE; then
    echo ""
    echo "Desktop environment:"
    echo "  1) ubuntu-xfce  (Standard, recommended)"
    echo "  2) alpine-xfce  (Ultra-light, ~200MB RAM — best for Pi 3)"
    echo "  3) arch-xfce    (Bleeding-edge)"
    echo "  4) fedora-xfce  (Alternative)"
    read -rp "Choice [1-4, default 1]: " n
    case "${n:-1}" in
      1) choice="ubuntu-xfce" ;; 2) choice="alpine-xfce" ;;
      3) choice="arch-xfce" ;; 4) choice="fedora-xfce" ;;
      *) die "Invalid choice." ;;
    esac
  else
    choice="$def"
  fi
  normalise_flavor "$choice"
}

ask_port() {
  local def="$1" label="$2" val=""
  if $HAS_WHIPTAIL && ! $NON_INTERACTIVE; then
    val=$(wt --title "PiCanvas — $label" --inputbox \
      "Port for $label (1024-65535). ENTER on <Ok> confirms:" 10 62 "$def") \
      || die "Setup cancelled. Press ENTER — nothing further runs."
  elif ! $NON_INTERACTIVE; then
    read -rp "$label port [$def]: " val; val="${val:-$def}"
  else
    val="$def"
  fi
  [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1024 && val <= 65535 )) \
    || die "Invalid port '$val' — use 1024-65535."
  echo "$val"
}

ask_yesno() {
  local question="$1" def="$2"
  if $NON_INTERACTIVE; then echo "$def"; return; fi
  if $HAS_WHIPTAIL; then
    # NOTE: whiptail renders <Yes> first, so an accidental Enter picks "Yes".
    # Default the cursor to <No> unless the saved default is explicitly true.
    if [[ "$def" == "true" ]]; then
      if wt --title "PiCanvas" --yesno "$question  (ENTER on highlighted button)" 9 62; then echo "true"; else echo "false"; fi
    else
      if wt --defaultno --title "PiCanvas" --yesno "$question  (ENTER on highlighted button)" 9 62; then echo "true"; else echo "false"; fi
    fi
  else
    local hint="Y/n" dflt="true"
    [[ "$def" == "false" ]] && { hint="y/N"; dflt="false"; }
    read -rp "$question [$hint]: " a; a="${a,,}"
    case "${a:-$dflt}" in y|yes|true) echo "true" ;; *) echo "false" ;; esac
  fi
}

ask_secret() {
  local prompt="$1" val=""
  if $HAS_WHIPTAIL && ! $NON_INTERACTIVE; then
    val=$(wt --title "PiCanvas" --passwordbox "$prompt" 10 72) || val=""
  elif ! $NON_INTERACTIVE; then
    read -rsp "$prompt" val; echo ""
  fi
  echo "$val"
}

# --- 2. Load existing config.env as defaults --------------------------------
DEF_FLAVOR="ubuntu-xfce"; DEF_WEB="3000"; DEF_HTTPS="3001"; DEF_TZ="UTC"
DEF_PUID="$(id -u "$RUN_AS" 2>/dev/null || echo 1000)"
DEF_PGID="$(id -g "$RUN_AS" 2>/dev/null || echo 1000)"
DEF_TS="false"; DEF_KEY=""; DEF_TITLE="PiCanvas"; DEF_TSHOST="picanvas"
if [[ -f "$CONFIG_FILE" ]]; then
  set -a; source "$CONFIG_FILE"; set +a
  DEF_FLAVOR="${DESKTOP_FLAVOR:-$DEF_FLAVOR}"
  DEF_WEB="${WEB_PORT:-$DEF_WEB}"; DEF_HTTPS="${CUSTOM_HTTPS_PORT:-$DEF_HTTPS}"
  DEF_TZ="${TZ:-$DEF_TZ}"; DEF_PUID="${PUID:-$DEF_PUID}"; DEF_PGID="${PGID:-$DEF_PGID}"
  DEF_TS="${USE_TAILSCALE:-$DEF_TS}"; DEF_KEY="${TAILSCALE_AUTHKEY:-$DEF_KEY}"
  DEF_TITLE="${TITLE:-$DEF_TITLE}"; DEF_TSHOST="${TS_HOSTNAME:-$DEF_TSHOST}"
fi
if [[ "$DEF_TZ" == "UTC" ]] && command -v timedatectl >/dev/null 2>&1; then
  DEF_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
fi

# --- 3. Interactive prompts --------------------------------------------------
cyan ""
cyan "  ____  _  ___Canvas  v$VERSION"
cyan "  One-command headless web workstation for Raspberry Pi"
cyan ""

step_begin "settings" noticker
FLAVOR="$(ask_choice_flavor "$DEF_FLAVOR")"
green "[PiCanvas] ✓ Desktop: $FLAVOR"
WEB_PORT="$(ask_port "$DEF_WEB" "Desktop HTTP")"
green "[PiCanvas] ✓ HTTP port: $WEB_PORT"
HTTPS_PORT="$(ask_port "$DEF_HTTPS" "Desktop HTTPS")"
green "[PiCanvas] ✓ HTTPS port: $HTTPS_PORT"
[[ "$WEB_PORT" == "$HTTPS_PORT" ]] && die "HTTP and HTTPS ports must differ."

if ! $NON_INTERACTIVE; then
  if $HAS_WHIPTAIL; then
    TZ_NEW=$(wt --title "PiCanvas — Timezone (Step 5 of 6)" --inputbox \
      "Timezone (e.g. UTC, Europe/Berlin, America/New_York). TAB jumps to <Ok>, then ENTER confirms:" 10 68 "$DEF_TZ") \
      || TZ_NEW="$DEF_TZ"
  else
    read -rp "Timezone [$DEF_TZ]: " TZ_NEW; TZ_NEW="${TZ_NEW:-$DEF_TZ}"
  fi
else
  TZ_NEW="$DEF_TZ"
fi
green "[PiCanvas] ✓ Timezone: $TZ_NEW"

USE_TS="$(ask_yesno "Enable remote access via Tailscale (reach your Pi from anywhere)?" "$DEF_TS")"
green "[PiCanvas] ✓ Tailscale: $USE_TS"
TS_KEY="$DEF_KEY"
if [[ "$USE_TS" == "true" ]]; then
  warn "Create a key at: https://login.tailscale.com/admin/settings/keys (reusable or ephemeral)."
  TS_KEY="$(ask_secret "Paste Tailscale auth key, ENTER on <Ok> confirms (empty = manual 'tailscale up' later): ")"
  [[ -z "$TS_KEY" ]] && TS_KEY="$DEF_KEY"
  if [[ -n "$TS_KEY" ]]; then green "[PiCanvas] ✓ Auth key saved."; else green "[PiCanvas] ✓ No key — manual 'tailscale up' later."; fi
fi

# --- 3b. Confirm summary (last chance to abort before writing anything) ------
TS_DISPLAY="$USE_TS"; [[ "$USE_TS" == "true" && -z "$TS_KEY" ]] && TS_DISPLAY="true (manual login later)"
SUMMARY="Desktop:  $FLAVOR\nHTTP:     $WEB_PORT\nHTTPS:    $HTTPS_PORT\nTimezone: $TZ_NEW\nTailscale: $TS_DISPLAY"
if ! $NON_INTERACTIVE; then
  if $HAS_WHIPTAIL; then
    drain_stdin
    whiptail --title "PiCanvas — Confirm" --yesno "Install with these settings?\n\n$SUMMARY" 15 62 \
      || die "Setup cancelled — re-run ./install.sh to try again."
  else
    echo ""
    echo "Install with these settings?"
    printf '%b\n' "$SUMMARY"
    read -rp "Continue? [Y/n]: " ok; ok="${ok,,}"
    case "${ok:-y}" in y|yes) ;; *) die "Setup cancelled." ;; esac
  fi
fi

# --- 4. Write config.env -----------------------------------------------------
step_done "settings"
step_begin "saving config"
TMP_CFG="$(mktemp)"
cat > "$TMP_CFG" <<EOF
# PiCanvas configuration — generated by install.sh v$VERSION on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Re-run ./install.sh to change, or edit and run: docker compose --env-file config.env up -d

DESKTOP_FLAVOR=$FLAVOR

WEB_PORT=$WEB_PORT
CUSTOM_HTTPS_PORT=$HTTPS_PORT

TZ=$TZ_NEW
TITLE=$DEF_TITLE

PUID=$DEF_PUID
PGID=$DEF_PGID

USE_TAILSCALE=$USE_TS
TAILSCALE_AUTHKEY=$TS_KEY
TS_HOSTNAME=$DEF_TSHOST
TS_EXTRA_ARGS=--advertise-exit-node=false
EOF
mv "$TMP_CFG" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
if [[ -n "${SUDO_USER:-}" ]]; then
  $SUDO chown "$RUN_AS:$(id -gn "$RUN_AS")" "$CONFIG_FILE" || true
fi
green "[PiCanvas] Wrote $CONFIG_FILE (flavor=$FLAVOR, web=$WEB_PORT/$HTTPS_PORT, tailscale=$USE_TS)"
step_done "saving config"

# --- 5. Dependencies ---------------------------------------------------------
chmod +x "$REPO_DIR/scripts/"*.sh
step_begin "Docker engine (quiet 2-6 min on a Pi — heartbeat below means working)"
$SUDO bash "$REPO_DIR/scripts/setup-docker.sh"
step_done "Docker engine"
step_begin "Tailscale pre-flight"
$SUDO bash "$REPO_DIR/scripts/setup-tailscale.sh"
step_done "Tailscale pre-flight"

# --- 6. Launch ----------------------------------------------------------------
step_begin "downloading desktop image (~300-800MB first run)"
mkdir -p "$REPO_DIR/data/config" "$REPO_DIR/data/tailscale"
if [[ -n "${SUDO_USER:-}" ]]; then
  $SUDO chown -R "$RUN_AS:$(id -gn "$RUN_AS")" "$REPO_DIR/data" || true
fi

COMPOSE=("docker" "compose" "--env-file" "$CONFIG_FILE" "-f" "$COMPOSE_FILE")
if [[ "$USE_TS" == "true" ]]; then
  COMPOSE+=("--profile" "tailscale")
fi

"${COMPOSE[@]}" pull || warn "Pull reported an issue — continuing with cached images if present."
step_done "downloading desktop image"
step_begin "starting containers"
"${COMPOSE[@]}" up -d
step_done "starting containers"

# --- 7. Wait for the desktop --------------------------------------------------
step_begin "waiting for desktop on port $WEB_PORT"
for i in $(seq 1 60); do
  if curl -fsS -m 2 "http://localhost:$WEB_PORT" >/dev/null 2>&1; then break; fi
  sleep 2
  (( i == 60 )) && warn "Desktop is still starting — give it another minute, then check 'docker compose ps'."
done
step_done "waiting for desktop on port $WEB_PORT"

# --- 8. Success banner --------------------------------------------------------
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; LAN_IP="${LAN_IP:-<PI-IP>}"
TS_IP=""
if [[ "$USE_TS" == "true" ]]; then
  sleep 3
  TS_IP="$(docker exec picanvas-tailscale tailscale ip -4 2>/dev/null | head -n1 || true)"
  [[ -z "$TS_IP" && -z "$TS_KEY" ]] && TS_IP="<run: docker exec picanvas-tailscale tailscale up>"
  [[ -z "$TS_IP" ]] && TS_IP="<starting — check: docker logs picanvas-tailscale>"
fi

echo ""
echo "=============================================================="
green "  PiCanvas is ready! ($FLAVOR)"
echo "=============================================================="
echo "  Local access (same Wi-Fi):"
cyan "    http://$LAN_IP:$WEB_PORT"
echo "  This machine:"
cyan "    http://localhost:$WEB_PORT"
if [[ "$USE_TS" == "true" ]]; then
  echo "  Remote access (Tailscale, from anywhere):"
  cyan "    http://$TS_IP:$WEB_PORT"
fi
echo ""
echo "  Files persist in ./data/config  |  Manage: docker compose ps / logs / down"
echo "  Docs: $REPO_DIR/README.md"
echo "=============================================================="

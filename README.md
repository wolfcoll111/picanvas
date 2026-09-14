# PiCanvas — one-command headless web workstation for Raspberry Pi.

Clone on Raspberry Pi OS Lite / Debian / Ubuntu Server, run one script, and get a
full XFCE desktop in your browser — on your LAN, or anywhere via Tailscale.

```bash
curl -fsSL https://github.com/wolfcoll111/picanvas/archive/refs/heads/main.tar.gz | tar -xz && cd picanvas-main && bash install.sh
```

Re-installing or retrying after a failed run? Step out of the folder first,
then wipe it (deleting the directory you're standing in breaks the download):

```bash
cd ~ && rm -rf ~/picanvas-main && curl -fsSL https://github.com/wolfcoll111/picanvas/archive/refs/heads/main.tar.gz | tar -xz && cd ~/picanvas-main && bash install.sh
```

> If you see `Permission denied` with `./install.sh`, use `bash install.sh`
> instead (fresh tarball/zip downloads don't keep the executable bit).
> Alternative: `chmod +x install.sh scripts/*.sh`, then `./install.sh` works.

Prefer git?

```bash
git clone https://github.com/wolfcoll111/picanvas.git && cd picanvas && bash install.sh
```

Headless / automated installs use the values already in `config.env`:

```bash
bash install.sh --non-interactive
```

---

## What you get

| Component | Details |
|---|---|
| Desktop | LinuxServer Webtop (XFCE) in Docker — browser-native, no client needed |
| LAN access | `http://<PI-IP>:3000` (port configurable) |
| Remote access | Optional Tailscale sidecar — same desktop on your tailnet from anywhere |
| Persistence | Desktop settings + installed files survive restarts in `./data/config` |
| Footprint | ~200MB RAM with Alpine, ~500MB with Ubuntu — Pi 3/4/5 friendly |

## Requirements

- Raspberry Pi 3/4/5 (or any ARM64/x86_64 mini PC) with 64-bit Raspberry Pi OS Lite,
  Debian 12+, or Ubuntu Server 22.04+
- 1GB+ RAM recommended (Alpine flavor works on 1GB boards), 8GB+ free disk
- Same Wi-Fi/LAN for local access; a [Tailscale](https://tailscale.com) account for remote
- `sudo` access. The installer adds Docker itself — nothing to pre-install.

## Desktop flavors

| `DESKTOP_FLAVOR` | Base | RAM (idle) | Pick when... |
|---|---|---|---|
| `ubuntu-xfce` (default) | Ubuntu + XFCE | ~500MB | Best app compatibility, Pi 4/5 |
| `alpine-xfce` | Alpine + XFCE | ~200MB | Pi 3 / 1GB boards, max headroom |
| `arch-xfce` | Arch + XFCE | ~400MB | You want the newest packages |
| `fedora-xfce` | Fedora + XFCE | ~500MB | You prefer the Fedora stack |

Aliases `xfce` -> `ubuntu-xfce` and `alpine-desktop` -> `alpine-xfce` are accepted.
Change any time: edit `config.env`, then `docker compose --env-file config.env up -d`.

## Configuration (`config.env`)

| Variable | Default | Meaning |
|---|---|---|
| `DESKTOP_FLAVOR` | `ubuntu-xfce` | Which Webtop image to run |
| `WEB_PORT` | `3000` | HTTP port (container 3000) |
| `CUSTOM_HTTPS_PORT` | `3001` | HTTPS port (container 3001) |
| `TZ` | `UTC` | Timezone, e.g. `Europe/Berlin` |
| `TITLE` | `PiCanvas` | Browser tab title |
| `PUID` / `PGID` | `1000`/`1000` | File ownership for `./data` |
| `USE_TAILSCALE` | `false` | `true` starts the Tailscale sidecar |
| `TAILSCALE_AUTHKEY` | _(empty)_ | Auth key for zero-touch join (see below) |
| `TS_HOSTNAME` | `picanvas` | Tailnet device name |
| `TS_EXTRA_ARGS` | `--advertise-exit-node=false` | Extra `tailscale up` flags |

## Tailscale remote access

1. Admin console -> **Settings -> Keys -> Generate auth key**
   ([login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)).
   Reusable or ephemeral both work; ephemeral is tidier for a Pi.
2. Re-run `bash install.sh`, answer **Yes** to Tailscale, paste the key —
   or set `USE_TAILSCALE=true` + key in `config.env` and run with `--non-interactive`.
3. Open `http://<TAILSCALE-IP>:3000` from any device on your tailnet.
   Find the IP with `docker exec picanvas-tailscale tailscale ip -4`.

No key handy? Leave it empty and join manually afterwards:

```bash
docker exec picanvas-tailscale tailscale up
```

## Daily use

```bash
docker compose --env-file config.env ps        # status
docker compose --env-file config.env logs -f   # follow logs
docker compose --env-file config.env down      # stop (files kept in ./data)
docker compose --env-file config.env --profile tailscale up -d   # start incl. Tailscale
```

Install apps inside the desktop with its native package manager
(`apt` on Ubuntu, `apk` on Alpine, `pacman` on Arch, `dnf` on Fedora) —
they persist in `./data/config`.

## Troubleshooting

- **Permission denied running `./install.sh`** — expected on fresh tarball
  downloads (the exec bit isn't preserved). Fix: run `bash install.sh`,
  or `chmod +x install.sh scripts/*.sh` first.
- **Browser tab crashes / renderer errors** — already mitigated via
  `shm_size: 1gb` and `seccomp=unconfined` in `docker-compose.yml`; do not remove them.
- **Port in use** — pick another `WEB_PORT` in `config.env` and re-run.
- **No `/dev/net/tun`** — `setup-tailscale.sh` loads it (`modprobe tun`);
  on restricted kernels enable the TUN module first.
- **Tailscale shows no IP** — `docker logs picanvas-tailscale`; expired auth keys
  need regenerating, then `docker exec picanvas-tailscale tailscale up --authkey tskey-...`.
- **Permission issues in `./data`** — match `PUID`/`PGID` to your user (`id -u`, `id -g`).
- **Old ARM boards (Pi Zero / 32-bit OS)** — use a 64-bit OS; Webtop images are
  ARM64/x86_64 only.

## Uninstall

```bash
docker compose --env-file config.env --profile tailscale down
sudo rm -rf ./data   # wipes desktop files + Tailscale state (optional)
```

## Layout

```text
picanvas/
+-- install.sh              # installer (menus via whiptail, plain prompts as fallback)
+-- config.env              # your settings
+-- docker-compose.yml      # Webtop + optional Tailscale sidecar
+-- README.md               # this file
+-- scripts/
    +-- setup-docker.sh     # Docker + Compose plugin installer
    +-- setup-tailscale.sh  # TUN device + state-dir pre-flight
```

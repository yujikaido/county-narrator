#!/usr/bin/env bash
# County Narrator -- operator console
#
# Interactive whiptail menu in the style of Proxmox VE Helper-Scripts.
# Direct subcommands also work for scripting and cron.
#
# `sudo update`                = open menu
# `sudo update <subcommand>`   = run directly (see `update help`)

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/county-narrator}"
BACKUP_DIR_DEFAULT="${BACKUP_DIR:-/var/backups/county-narrator}"
APP_PORT="${APP_PORT:-8001}"
SERVICE="${SERVICE:-county-narrator}"

# --- Branding ----------------------------------------------------------------
APP_NAME="County Narrator"
APP_TAG="self-hosted TTS for auto-attendant & voicemail greetings"

# --- Colors ------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_CYAN=$'\e[1;36m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

log()  { printf "%s[+]%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf "%s[!]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[x]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
ok()   { printf "%s[OK]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
hdr()  { printf "\n%s── %s ──%s\n" "$C_BOLD" "$*" "$C_RESET"; }
die()  { err "$*"; exit 1; }

require_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root (try: sudo update)"; }
require_dir()  { [[ -d "$INSTALL_DIR" ]] || die "Install dir not found: $INSTALL_DIR"; cd "$INSTALL_DIR"; }
have_whiptail() { command -v whiptail >/dev/null 2>&1; }

# Dark theme with Narrator-blue accents. The key fix vs the default: window=,black
# (the dialog box background) so the menu isn't a white panel.
export NEWT_COLORS='
root=,black
window=,black
shadow=,black
border=brightblue,black
title=brightblue,black
textbox=white,black
listbox=white,black
actlistbox=black,blue
sellistbox=white,black
actsellistbox=black,blue
button=black,blue
compactbutton=white,black
checkbox=white,black
actcheckbox=black,blue
entry=white,black
disentry=lightgray,black
label=white,black
roottext=white,black
helpline=white,black
emptyscale=,lightgray
fullscale=,blue
'
WT_BACKTITLE="$APP_NAME -- Operator Console"
WT_H=22
WT_W=78
WT_MENU_H=12

print_banner() {
  clear
  cat <<'EOF'

    ____                  _           _   _                      _
   / ___|___  _   _ _ __ | |_ _   _  | \ | | __ _ _ __ _ __ __ _| |_ ___  _ __
  | |   / _ \| | | | '_ \| __| | | | |  \| |/ _` | '__| '__/ _` | __/ _ \| '__|
  | |__| (_) | |_| | | | | |_| |_| | | |\  | (_| | |  | | | (_| | || (_) | |
   \____\___/ \__,_|_| |_|\__|\__, | |_| \_|\__,_|_|  |_|  \__,_|\__\___/|_|
                              |___/        🎙  PBX-ready WAVs for NEC 3C Host
EOF
  printf "       %s%s%s\n\n" "$C_DIM" "$APP_TAG" "$C_RESET"
}

stack_summary() {
  local running total ver commit
  running=$(docker compose ps --status running -q 2>/dev/null | wc -l)
  total=$(docker compose config --services 2>/dev/null | wc -l)
  ver="?"; commit="?"
  [[ -f VERSION ]] && ver=$(head -1 VERSION | tr -d '[:space:]')
  [[ -d .git ]] && commit=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
  printf "v%s @ %s | %d/%d services up" "$ver" "$commit" "$running" "$total"
}

pause() {
  echo
  printf "%s" "${C_DIM}Press Enter to return to the menu...${C_RESET}"
  read -r _ < /dev/tty || true
}

ask_yesno() {
  local question="$1"
  if have_whiptail; then
    whiptail --backtitle "$WT_BACKTITLE" --title "Confirm" --yesno "$question" 10 70
    return $?
  else
    printf "%s [y/N] " "$question"
    read -r answer < /dev/tty
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

# --- Subcommands -------------------------------------------------------------

# apply [--main] [--hard] : deploy the latest tagged release (or main)
# --hard ALSO pulls a fresh base image to pick up upstream CVE patches.
cmd_apply() {
  require_root; require_dir
  local do_hard=0 track="${NARRATOR_TRACK:-tag}"
  for arg in "$@"; do
    case "$arg" in
      --main) track="main" ;;
      --hard) do_hard=1 ;;
      *) warn "Unknown apply arg: $arg" ;;
    esac
  done

  hdr "Syncing from git"
  if [[ ! -d .git ]]; then
    warn "Not a git checkout -- skipping git sync."
  else
    local old new target
    old=$(git rev-parse HEAD 2>/dev/null || echo "")
    if ! git fetch --quiet --tags --force origin; then
      err "git fetch failed -- check network / repo URL"
      return 1
    fi
    # SECURITY: production deploy target = the latest *tagged release*, never
    # raw main. A human must deliberately `git tag vX.Y.Z` a reviewed commit
    # for it to land here. Set NARRATOR_TRACK=main (or pass --main) to opt in.
    if [[ "$track" == "main" ]]; then
      warn "NARRATOR_TRACK=main -- deploying un-tagged HEAD of main (NOT recommended for production)"
      target="origin/main"
    else
      target=$(git tag -l 'v*' --sort=-v:refname | head -1)
      if [[ -z "$target" ]]; then
        err "No version tags found in the repo."
        err "On your dev machine: git tag v1.0.0 && git push --tags"
        err "(Or run with --main to deploy untagged main, not recommended.)"
        return 1
      fi
      log "Latest release tag: $target"
    fi
    git reset --hard "$target" >/dev/null 2>&1 || { err "git reset to $target failed"; return 1; }
    chmod +x "$INSTALL_DIR"/update.sh "$INSTALL_DIR"/install.sh 2>/dev/null || true
    new=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [[ "$old" == "$new" ]]; then
      log "Already on $target -- no code changes."
    else
      log "Deployed $target ($(git rev-parse --short "$old") -> $(git rev-parse --short "$new"))"
      echo
      printf "%sChanged files:%s\n" "$C_BOLD" "$C_RESET"
      git diff --stat "$old..$new" | sed 's/^/  /'
      echo
    fi
  fi

  local build_pull="--pull=false"
  if [[ "$do_hard" -eq 1 ]]; then
    hdr "Pulling base image (CVE refresh)"
    docker compose pull 2>/dev/null || true
    build_pull="--pull"
  fi

  hdr "Building container"
  DOCKER_BUILDKIT=1 docker compose build "$build_pull" --progress=plain || die "build failed"

  hdr "Restarting stack"
  docker compose up -d --remove-orphans || die "docker compose up failed"
  ok "deploy complete"
  cmd_status
}

cmd_status() {
  require_dir
  hdr "Stack"
  docker compose ps
  echo
  # After a rebuild the container needs a moment to start listening (and on
  # first run it downloads ~2 GB of model weights), so poll instead of
  # probing once — a healthy app shouldn't look dead because we asked early.
  local tries=0 max=30 waited=0
  while true; do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null 2>&1; then
      [ "$waited" -eq 1 ] && echo
      ok "health endpoint responding on :${APP_PORT}"
      # Model may still be warming up even when the API is alive
      local loaded
      loaded=$(curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" 2>/dev/null | grep -o '"model_loaded":[a-z]*' | cut -d: -f2)
      if [[ "$loaded" == "false" ]]; then
        warn "TTS model still loading (first run downloads ~2 GB) -- 'update logs' to watch"
      fi
      break
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      [ "$waited" -eq 1 ] && echo
      warn "health endpoint not responding on :${APP_PORT} (waited ${max}s — try 'update logs')"
      break
    fi
    if [ "$tries" -eq 1 ]; then printf '   waiting for the app to start'; waited=1; fi
    printf '.'
    sleep 1
  done
}

cmd_logs()    { require_dir; docker compose logs -f --tail=200; }
cmd_restart() { require_root; require_dir; docker compose restart; ok "restarted"; cmd_status; }
cmd_shell()   { require_dir; docker compose exec "$SERVICE" bash 2>/dev/null || docker compose exec "$SERVICE" sh; }

cmd_os() {
  require_root
  hdr "apt update + upgrade (OS only)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get upgrade -y -qq && apt-get --yes autoremove -qq
  ok "OS up to date"
}

cmd_gpu() {
  hdr "GPU"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi
  else
    warn "nvidia-smi not found on the host"
  fi
  hdr "GPU inside container"
  docker compose exec "$SERVICE" python -c \
    "import torch; print('cuda available:', torch.cuda.is_available()); print('device:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'cpu')" \
    2>/dev/null || warn "container not running"
}

cmd_disk() {
  hdr "Host disk"
  df -h / /var/lib/docker 2>/dev/null | column -t
  hdr "Docker disk usage"
  docker system df
  hdr "$APP_NAME data dir"
  if [[ -d "$INSTALL_DIR/data" ]]; then
    du -sh "$INSTALL_DIR/data" 2>/dev/null | awk '{print "  data/: " $1}'
    [[ -d "$INSTALL_DIR/data/voices" ]]   && du -sh "$INSTALL_DIR/data/voices"   2>/dev/null | awk '{print "  voices/: " $1}'
    [[ -d "$INSTALL_DIR/data/outputs" ]]  && du -sh "$INSTALL_DIR/data/outputs"  2>/dev/null | awk '{print "  outputs/: " $1}'
    [[ -d "$INSTALL_DIR/data/hf-cache" ]] && du -sh "$INSTALL_DIR/data/hf-cache" 2>/dev/null | awk '{print "  hf-cache/ (model weights): " $1}'
  else
    warn "No data/ dir at $INSTALL_DIR/data"
  fi
}

cmd_prune() {
  hdr "Docker prune"
  echo "Removes: stopped containers, dangling images, unused build cache + networks."
  echo "Volumes are NOT touched -- your $APP_NAME data/ is safe."
  echo
  ask_yesno "Proceed with Docker prune?" || { warn "Cancelled."; return 0; }
  hdr "Before"; docker system df; echo
  log "Pruning stopped containers..."; docker container prune -f
  log "Pruning dangling images...";    docker image prune -f
  log "Pruning unused build cache..."; docker builder prune -f
  log "Pruning unused networks...";    docker network prune -f
  hdr "After"; docker system df
  ok "Prune complete."
}

cmd_health() {
  require_dir
  hdr "Health endpoint"
  curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" && echo || warn "no response on :${APP_PORT}"
  hdr "Recent errors in container logs"
  docker compose logs --tail=300 2>/dev/null | grep -iE "error|fatal|unhandled|traceback" | tail -20 || echo "  (none)"
}

# Backup = voices + generated audio. The hf-cache (model weights) is excluded:
# it's ~2 GB of re-downloadable data.
cmd_backup() {
  require_dir
  local dest="${1:-$BACKUP_DIR_DEFAULT}"
  mkdir -p "$dest"
  local ts file
  ts="$(date +%Y%m%d-%H%M%S)"
  file="$dest/narrator-data-$ts.tar.gz"
  log "backing up data/ (excluding model cache) to $file"
  tar --exclude='data/hf-cache' -czf "$file" -C "$INSTALL_DIR" data || die "backup failed"
  ok "backup written: $file"
}

cmd_restore() {
  require_root; require_dir
  local file="${1:-}"
  [[ -z "$file" || ! -f "$file" ]] && die "Usage: update restore /path/to/narrator-data-YYYYMMDD-HHMMSS.tar.gz"
  ask_yesno "This will OVERWRITE voices and generated audio in data/. Continue?" || { warn "Cancelled."; return 0; }
  docker compose down
  rm -rf "$INSTALL_DIR/data/voices" "$INSTALL_DIR/data/outputs"
  tar -xzf "$file" -C "$INSTALL_DIR" || die "restore failed"
  docker compose up -d
  ok "restore complete from $file"
}

cmd_audit() {
  require_dir
  hdr "Outdated python packages (inside the image)"
  docker compose exec "$SERVICE" pip list --outdated 2>/dev/null | head -25 || warn "container not running"
  hdr "Base image age"
  local img created
  img=$(docker compose images -q "$SERVICE" 2>/dev/null | head -1)
  if [[ -n "$img" ]]; then
    created=$(docker image inspect "$img" --format '{{.Created}}' 2>/dev/null || echo "?")
    echo "  image:   $img"
    echo "  created: $created"
    echo
    echo "  Stale base image = unpatched system libs. 'update apply --hard' refreshes it."
  fi
}

cmd_url() {
  local ip
  ip=$(hostname -I | awk '{print $1}')
  local msg="Local URL:  http://$ip:${APP_PORT}\n\nReverse proxy: whatever you set up in Nginx Proxy Manager\n(e.g. https://narrator.admin)."
  if have_whiptail; then
    whiptail --backtitle "$WT_BACKTITLE" --title "Web UI" --msgbox "$msg" 12 70
  else
    printf "%b\n" "$msg"
  fi
}

cmd_help() {
  cat <<EOF
${C_BOLD}$APP_NAME -- operator console${C_RESET}

  ${C_CYAN}update${C_RESET}                            interactive whiptail menu
  ${C_CYAN}update apply${C_RESET} [--hard] [--main]    deploy latest tagged release, rebuild, restart
                                    (--hard also patches base-image CVEs;
                                     --main opts in to bleeding-edge main)
  ${C_CYAN}update os${C_RESET}                         apt upgrade the LXC
  ${C_CYAN}update status${C_RESET}                     container + health status
  ${C_CYAN}update logs${C_RESET}                       follow container logs
  ${C_CYAN}update restart${C_RESET}                    restart the container
  ${C_CYAN}update shell${C_RESET}                      shell into the container
  ${C_CYAN}update health${C_RESET}                     health endpoint + recent errors
  ${C_CYAN}update gpu${C_RESET}                        nvidia-smi + CUDA check inside container
  ${C_CYAN}update disk${C_RESET}                       host disk + Docker + data dir usage
  ${C_CYAN}update prune${C_RESET}                      remove stopped containers / dangling images
  ${C_CYAN}update backup${C_RESET} [dir]               tar.gz voices + generated audio
  ${C_CYAN}update restore${C_RESET} <file>             restore data/ from a backup tarball
  ${C_CYAN}update audit${C_RESET}                      outdated packages + base-image age
  ${C_CYAN}update url${C_RESET}                        show the Web UI URL
  ${C_CYAN}update help${C_RESET}                       this help

  ${C_DIM}update --hard${C_RESET}    = update apply --hard
EOF
}

# --- Interactive menu --------------------------------------------------------
menu_main() {
  while true; do
    local title choice rc
    title="$APP_NAME  |  $(stack_summary)"
    choice=$(whiptail --backtitle "$WT_BACKTITLE" \
                      --title "$title" \
                      --menu "Choose an action:" \
                      $WT_H $WT_W $WT_MENU_H \
                      "1"  "Apply update       (latest release tag, rebuild, restart)" \
                      "2"  "Hard update        (also patch base-image CVEs)" \
                      "3"  "OS update          (apt upgrade the LXC)" \
                      "4"  "Service status     (docker compose ps)" \
                      "5"  "Tail logs          (follow container logs)" \
                      "6"  "Restart container" \
                      "7"  "Shell into container" \
                      "8"  "Health check       (port / endpoint / recent errors)" \
                      "9"  "GPU check          (nvidia-smi + CUDA in container)" \
                      "10" "Disk & storage     (df / data dir size)" \
                      "11" "Prune Docker       (frees space - keeps data)" \
                      "12" "Backup data        (voices + audio to tar.gz)" \
                      "13" "Restore data       (from a backup tar.gz)" \
                      "14" "Vuln scan          (outdated pkgs + base image age)" \
                      "15" "Web UI URL hint" \
                      "Q"  "Quit" \
                      3>&1 1>&2 2>&3)
    rc=$?
    [[ "$rc" -ne 0 ]] && { clear; echo "Bye."; exit 0; }

    clear; print_banner
    case "$choice" in
      1)  cmd_apply;          pause ;;
      2)  cmd_apply --hard;   pause ;;
      3)  cmd_os;             pause ;;
      4)  cmd_status;         pause ;;
      5)  cmd_logs ;;
      6)  cmd_restart;        pause ;;
      7)  cmd_shell ;;
      8)  cmd_health;         pause ;;
      9)  cmd_gpu;            pause ;;
      10) cmd_disk;           pause ;;
      11) cmd_prune;          pause ;;
      12) cmd_backup;         pause ;;
      13) local f; f=$(whiptail --backtitle "$WT_BACKTITLE" --inputbox "Path to backup tarball:" 10 70 "$BACKUP_DIR_DEFAULT/" 3>&1 1>&2 2>&3) && cmd_restore "$f"; pause ;;
      14) cmd_audit;          pause ;;
      15) cmd_url ;;
      Q|q) clear; echo "Bye."; exit 0 ;;
      *) warn "Unknown choice: $choice"; sleep 1 ;;
    esac
  done
}

# --- Dispatch ----------------------------------------------------------------
main() {
  local sub="${1:-}"
  case "$sub" in
    apply)        shift; cmd_apply "$@" ;;
    --hard)       cmd_apply --hard ;;
    status)       cmd_status ;;
    logs)         cmd_logs ;;
    restart)      cmd_restart ;;
    os)           cmd_os ;;
    gpu)          cmd_gpu ;;
    disk)         cmd_disk ;;
    prune)        cmd_prune ;;
    backup)       shift; cmd_backup "$@" ;;
    restore)      shift; cmd_restore "$@" ;;
    audit)        cmd_audit ;;
    health)       cmd_health ;;
    shell)        cmd_shell ;;
    url)          cmd_url ;;
    help|-h|--help) cmd_help ;;
    "")           if have_whiptail; then print_banner; menu_main; else cmd_help; fi ;;
    *)            err "unknown command: $sub"; echo; cmd_help; exit 1 ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# County Narrator -- installer for an existing Debian 12/13 LXC (or VM).
#
# Assumes NVIDIA drivers are already working in the container (nvidia-smi).
# Safe to re-run; each step is idempotent.
#
#   Option A (recommended): clone from GitHub, then run
#       git clone https://github.com/yujikaido/county-narrator.git /opt/county-narrator
#       bash /opt/county-narrator/install.sh
#
#   Option B: copy this folder anywhere (e.g. via WinSCP) and run
#       bash install.sh
#     -- it will copy itself into /opt/county-narrator and continue there.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/county-narrator}"
APP_PORT="${APP_PORT:-8001}"

C_CYAN=$'\e[1;36m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_RESET=$'\e[0m'
log()  { printf "%s[+]%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf "%s[!]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
ok()   { printf "%s[OK]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
die()  { printf "%s[x]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. Base packages ---------------------------------------------------------
log "Installing base packages (curl, git, whiptail, rsync)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git whiptail rsync >/dev/null
ok "Base packages ready"

# --- 2. Put the app in /opt/county-narrator ------------------------------------
if [[ "$SCRIPT_DIR" != "$INSTALL_DIR" ]]; then
  log "Copying app from $SCRIPT_DIR to $INSTALL_DIR ..."
  mkdir -p "$INSTALL_DIR"
  rsync -a --exclude data/ --exclude .git/ "$SCRIPT_DIR"/ "$INSTALL_DIR"/
  # Preserve git metadata if the source was a clone (enables `update apply`)
  [[ -d "$SCRIPT_DIR/.git" ]] && rsync -a "$SCRIPT_DIR/.git" "$INSTALL_DIR"/
fi
cd "$INSTALL_DIR"
mkdir -p data
chmod +x update.sh install.sh 2>/dev/null || true
ok "App files in $INSTALL_DIR"

if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  warn "Not a git checkout -- 'update apply' won't be able to pull releases."
  warn "After you create the GitHub repo, link it with:"
  warn "  cd $INSTALL_DIR && git init && git remote add origin <REPO_URL> && git fetch && git reset --hard origin/main"
fi

# --- 3. Docker ------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null
  ok "Docker installed"
else
  ok "Docker already installed"
fi

# --- 4. NVIDIA container toolkit (only if a GPU is visible) ----------------------
GPU=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  GPU=1
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    log "Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y -qq nvidia-container-toolkit >/dev/null
    nvidia-ctk runtime configure --runtime=docker >/dev/null
    ok "NVIDIA Container Toolkit installed"
  else
    ok "NVIDIA Container Toolkit already installed"
  fi
  # Unprivileged LXCs can't manage device cgroups from inside; the LXC config
  # on the Proxmox host handles device access instead.
  if grep -q '^#no-cgroups' /etc/nvidia-container-runtime/config.toml 2>/dev/null \
     || ! grep -q 'no-cgroups = true' /etc/nvidia-container-runtime/config.toml 2>/dev/null; then
    sed -i 's/^#no-cgroups = false/no-cgroups = true/; s/^no-cgroups = false/no-cgroups = true/' \
      /etc/nvidia-container-runtime/config.toml 2>/dev/null || true
  fi
  systemctl restart docker
  log "GPU detected: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
  cp -f docker-compose.gpu.yml docker-compose.override.yml
  ok "GPU override enabled (docker-compose.override.yml)"
else
  warn "No working nvidia-smi -- building CPU-only (it will run, slowly)."
  rm -f docker-compose.override.yml
fi

# --- 5. Operator console ('update' command) ---------------------------------------
log "Installing 'update' command..."
cat > /usr/local/bin/update <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/update.sh" "\$@"
EOF
chmod +x /usr/local/bin/update
ok "'sudo update' opens the operator console"

# --- 6. Build & start ----------------------------------------------------------------
log "Building container (first build downloads several GB; be patient)..."
DOCKER_BUILDKIT=1 docker compose build || die "Docker build failed"
docker compose up -d --remove-orphans || die "docker compose up failed"

IP=$(hostname -I | awk '{print $1}')
echo
ok "County Narrator is starting."
echo "    Web UI:  http://$IP:$APP_PORT"
echo "    First start downloads the TTS model (~2 GB) -- the UI shows"
echo "    'Warming up' until it finishes. Watch with: update logs"
echo "    Operator console: sudo update"

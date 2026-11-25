#!/bin/bash
# Reach workstation bootstrap for Debian/Ubuntu (including WSL).
#   ./install.sh         base setup: packages, Docker, mise tools, dotfiles, SSH key
#   ./install.sh --dev   also the Reach dev environment: repos, config files, local hosts, mkcert CA
# Environment: GIT_USER_NAME / GIT_USER_EMAIL (git identity), SYSINIT_REF (branch or tag of sysinit to deploy),
# SYSINIT_WIN_CAROOT (mkcert CA to copy into ~/.local/share/mkcert; install.ps1 passes the Windows one).
set -euo pipefail

DEV=false
case "${1:-}" in
  "") ;;
  --dev|-d) DEV=true ;;
  *) echo "Usage: $0 [--dev]" >&2; exit 1 ;;
esac

SYSINIT_REPO=https://github.com/withreach/sysinit.git
SYSINIT_REF="${SYSINIT_REF:-main}"
REACH_DEVOPS_REPO=git@github.com:withreach/reach-devops.git
REACH_DEVOPS_BRANCH=master
REACH_BASE="$HOME/withreach"
REACH_DEV="$REACH_BASE/dev"
REACH_V2="$REACH_DEV/repos/v2"
HOSTS_BEGIN="# BEGIN reach dev hosts"
HOSTS_END="# END reach dev hosts"
DEV_HOSTS=(
  admin.rch.local admin-api.rch.local checkout.rch.local portal.rch.local
  reports.rch.local stash.rch.local redirect.rch.local vue.admin.rch.local
)
MISE_TOOLS=(
  amazon-ecr-credential-helper awscli claude github-cli granted jq mkcert
  pre-commit python@3.11 python@3.14 starship usage uv worktrunk
)
# mise release signing key (https://mise.jdx.dev/installing-mise.html)
MISE_GPG_KEY=24853EC9F655CE80B48E6C3A8B81C9D17413A06D
# Fixed path: reach-devops' docker-compose.ssl.yml mounts it into the cert generator
MKCERT_CAROOT="$HOME/.local/share/mkcert"
GCM_WSL="/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager.exe"
# Files in home/ owned by sysinit and refreshed on every run; everything else is only created if missing
MANAGED_FILES_RE='^(\.profile\.d/.*|\.config/git/sysinit\.gitconfig)$'
# shellcheck disable=SC2088 # git expands ~ in include.path
SYSINIT_GITCONFIG="~/.config/git/sysinit.gitconfig"

WARNINGS=()

log() { echo "==> $*"; }
warn() {
  echo "WARNING: $*" >&2
  WARNINGS+=("$*")
}
apt_get() { sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }
is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qsi microsoft /proc/sys/kernel/osrelease; }
# stdin may be the `wget | bash` pipe; prompts and interactive tools need the terminal instead
has_tty() { (exec </dev/tty) 2>/dev/null; }

[[ -r /etc/debian_version ]] || { echo "Debian/Ubuntu only" >&2; exit 1; }
[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not root" >&2; exit 1; }

install_packages() {
  log "System packages"
  apt_get update
  apt_get install -y bash-completion ca-certificates curl gcc git gnupg \
    libnss3-tools locales make openssh-client openssl postgresql-client rsync unzip xclip xsel zip
  # Debian's locale-gen only builds locales enabled in /etc/locale.gen
  sudo sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  sudo locale-gen en_US.UTF-8
}

# WSL distros (Debian in particular) may boot without systemd, which Docker needs
ensure_wsl_systemd() {
  is_wsl || return 0
  [[ -d /run/systemd/system ]] && return 0
  log "Enabling systemd in /etc/wsl.conf"
  sudo touch /etc/wsl.conf
  sudo sed -i '/^[[:space:]]*systemd[[:space:]]*=/d' /etc/wsl.conf
  if grep -qx '\[boot\]' /etc/wsl.conf; then
    sudo sed -i '/^\[boot\]$/a systemd=true' /etc/wsl.conf
  else
    printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
  fi
  warn "systemd was enabled in /etc/wsl.conf; from Windows run 'wsl --terminate ${WSL_DISTRO_NAME:-<distro>}', then re-run this script"
}

# The Reach repositories are private and cloned over SSH; fail before the long install if GitHub rejects us
check_github_ssh() {
  log "GitHub SSH access"
  local out
  out="$(ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 </dev/null || true)"
  if [[ "$out" != *"successfully authenticated"* ]]; then
    echo "$out" >&2
    echo "ERROR: --dev needs an SSH key in ~/.ssh (or ssh-agent) that is registered with your GitHub account." >&2
    echo "On Windows pass -SSHKey <path> to install.ps1, or put the key in ~/.ssh in WSL, then re-run." >&2
    exit 1
  fi
}

install_ssm_plugin() {
  command -v session-manager-plugin >/dev/null && return
  log "AWS Session Manager plugin"
  local arch deb
  case "$(dpkg --print-architecture)" in
    amd64) arch=ubuntu_64bit ;;
    arm64) arch=ubuntu_arm64 ;;
    *) warn "no Session Manager plugin for $(dpkg --print-architecture); skipped"; return ;;
  esac
  deb="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$deb" "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/$arch/session-manager-plugin.deb"
  apt_get install -y "$deb"
  rm -f "$deb"
}

install_docker() {
  log "Docker"
  # Docker Desktop's WSL integration provides its own docker CLI and daemon; docker-ce would conflict with it
  if [[ -d /mnt/wsl/docker-desktop || "$(readlink -f /usr/bin/docker 2>/dev/null)" == /mnt/wsl/docker-desktop/* ]]; then
    warn "Docker Desktop WSL integration is enabled; docker-ce not installed. Disable the integration for this distro in Docker Desktop and re-run to use docker-ce."
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt_get update
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  if [[ -d /run/systemd/system ]]; then
    sudo systemctl enable --now docker
  else
    sudo service docker start || warn "could not start Docker (no systemd); start it with: sudo service docker start"
  fi
}

install_mise() {
  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v mise >/dev/null; then
    log "mise"
    local dir
    dir="$(mktemp -d)"
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$MISE_GPG_KEY"
    curl -fsSL https://mise.jdx.dev/install.sh.sig | gpg --decrypt >"$dir/install.sh"
    sh "$dir/install.sh"
    rm -rf "$dir"
  fi
  log "mise tools"
  mise use --global --yes "${MISE_TOOLS[@]}" || warn "mise tool install failed (GitHub rate limit?); re-run later"
}

# name/email: environment, then existing git config, then ask. Never invent one: useConfigOnly makes git
# refuse to commit without it, which beats commits with a bogus address.
git_identity() {
  local name email
  name="${GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || true)}"
  email="${GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
  # left over from the old template substitution
  [[ "$name" == *@GIT_USER_NAME@* ]] && name=""
  [[ "$email" == *@GIT_USER_EMAIL@* ]] && email=""
  if has_tty; then
    [[ -n "$name" ]] || read -rp "Your full name for git commits: " name </dev/tty
    [[ -n "$email" ]] || read -rp "Your work email for git commits: " email </dev/tty
  fi
  if [[ -n "$name" ]]; then git config --global user.name "$name"; else warn "git user.name not set; run: git config --global user.name 'Your Name'"; fi
  if [[ -n "$email" ]]; then git config --global user.email "$email"; else warn "git user.email not set; run: git config --global user.email you@example.com"; fi
  echo "Git identity: ${name:-?} <${email:-?}>"
}

configure_git() {
  # Include the managed defaults first, so anything in ~/.gitconfig overrides them
  if ! git config --global --get-all include.path 2>/dev/null | grep -qxF "$SYSINIT_GITCONFIG"; then
    local tmp
    tmp="$(mktemp)"
    { printf '[include]\n\tpath = %s\n' "$SYSINIT_GITCONFIG"; cat "$HOME/.gitconfig" 2>/dev/null || true; } >"$tmp"
    mv "$tmp" "$HOME/.gitconfig"
    chmod 644 "$HOME/.gitconfig"
  fi

  # Replace the plain-text "store" helper from older installs; on WSL share Windows' Git Credential Manager
  local helper
  helper="$(git config --global --get credential.helper 2>/dev/null || true)"
  if [[ -z "$helper" || "$helper" == store ]]; then
    git config --global --unset-all credential.helper 2>/dev/null || true
    if is_wsl && [[ -x "$GCM_WSL" ]]; then
      git config --global credential.helper "${GCM_WSL// /\\ }"
    else
      git config --global credential.helper "cache --timeout=28800"
    fi
  fi

  git_identity
}

deploy_dotfiles() {
  log "Dotfiles"
  local src=""
  [[ -n "${BASH_SOURCE[0]:-}" ]] && src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -z "$src" || ! -d "$src/home" ]]; then
    src="$HOME/sysinit"
    if [[ ! -d "$src/.git" ]]; then
      git clone -q "$SYSINIT_REPO" "$src"
    fi
    git -C "$src" fetch -q --tags origin "$SYSINIT_REF"
    git -C "$src" checkout -q --detach FETCH_HEAD
  fi

  rm -f "$HOME/.profile.d/sysinit" "$HOME/.profile.d/00-shell.sh" "$HOME/.profile.d/aws" # replaced by 20-mise.sh / 30-completions.sh / 50-aws.sh
  local file rel
  while IFS= read -r -d '' file; do
    rel="${file#"$src/home/"}"
    if [[ "$rel" =~ $MANAGED_FILES_RE ]]; then
      mkdir -p "$(dirname "$HOME/$rel")"
      cp "$file" "$HOME/$rel"
    else
      copy_if_missing "$file" "$HOME/$rel"
    fi
  done < <(find "$src/home" -type f -print0)
  chmod 700 "$HOME/.profile.d"
  configure_git

  if ! grep -qs "sysinit: load custom profile settings" "$HOME/.bashrc"; then
    cat >>"$HOME/.bashrc" <<'EOF'
# BEGIN sysinit: load custom profile settings
for profile_file in "$HOME"/.profile.d/*; do
  [ -f "$profile_file" ] && [ -r "$profile_file" ] && source "$profile_file"
done
# END sysinit: load custom profile settings
EOF
  fi
}

configure_hosts() {
  log "/etc/hosts"
  # Older installs added a passwordless `sed -i * /etc/hosts` rule, which allowed running any command as root.
  # Nothing in reach-devops needs passwordless access to /etc/hosts.
  sudo rm -f "/etc/sudoers.d/$USER-reach"

  if is_wsl; then
    # WSL regenerates /etc/hosts from the Windows hosts file, where install.ps1 adds these entries
    log "WSL: *.rch.local hosts entries come from the Windows hosts file"
    return
  fi
  local tmp
  tmp="$(mktemp)"
  {
    echo "$HOSTS_BEGIN"
    printf '127.0.0.1 %s\n' "${DEV_HOSTS[@]}"
    echo "$HOSTS_END"
  } >"$tmp"
  sudo sed -i "\|^$HOSTS_BEGIN\$|,\|^$HOSTS_END\$|d" /etc/hosts
  # shellcheck disable=SC2024 # $tmp is user-owned; only tee needs root
  sudo tee -a /etc/hosts <"$tmp" >/dev/null
  rm -f "$tmp"
}

# The mkcert CA lives in ~/.local/share/mkcert, which reach-devops' reach-local-certgen container mounts to
# sign httpd/ssl.crt. On WSL, install.ps1 passes the Windows CA (SYSINIT_WIN_CAROOT) and it is copied there,
# so the certificates are trusted by Windows browsers too (httpd/README.md, "Copy CA to WSL").
setup_mkcert() {
  log "mkcert CA"
  local dir="$MKCERT_CAROOT" win="${SYSINIT_WIN_CAROOT:-}" bak
  # Docker creates a missing bind-mount source as root
  if [[ -d "$dir" && ! -O "$dir" ]]; then
    sudo chown -R "$USER:" "$dir"
  fi
  mkdir -p "$dir"

  if [[ -n "$win" ]]; then
    if [[ -f "$win/rootCA.pem" && -f "$win/rootCA-key.pem" ]]; then
      if ! cmp -s "$win/rootCA.pem" "$dir/rootCA.pem"; then
        if [[ -f "$dir/rootCA.pem" ]]; then
          bak="$dir.bak-$(date +%Y%m%d%H%M%S)"
          cp -a "$dir" "$bak"
          echo "Backed up the previous mkcert CA to $bak"
        fi
        cp "$win/rootCA.pem" "$dir/rootCA.pem"
        cp "$win/rootCA-key.pem" "$dir/rootCA-key.pem"
        echo "Copied the Windows mkcert CA into $dir"
      fi
    else
      warn "no mkcert CA in $win; WSL uses its own CA, which Windows browsers will not trust"
    fi
  fi
  [[ -f "$dir/rootCA-key.pem" ]] && chmod 600 "$dir/rootCA-key.pem"
  [[ -f "$dir/rootCA.pem" ]] && chmod 644 "$dir/rootCA.pem"

  # Creates the CA if there is none yet, and trusts it in the Linux system and NSS stores
  if ! CAROOT="$dir" mise exec -- mkcert -install; then
    warn "mkcert -install failed; re-run once mise has installed mkcert"
    return
  fi

  # Keep reach-devops in step with the CA: certgen skips generation while httpd/ssl.crt exists, and
  # mkcert/install-ca.sh copies mkcert/rootCA.pem over the CA certificate
  local crt="$REACH_DEV/httpd/ssl.crt" exported="$REACH_DEV/mkcert/rootCA.pem"
  if [[ -f "$crt" ]] && ! openssl verify -CAfile "$dir/rootCA.pem" "$crt" >/dev/null 2>&1; then
    rm -f "$crt" "$REACH_DEV/httpd/ssl.key"
    log "Removed httpd/ssl.crt (not signed by this CA); reach-local-certgen regenerates it on the next 'docker compose --profile admin up'"
  fi
  if [[ -f "$exported" ]] && ! cmp -s "$dir/rootCA.pem" "$exported"; then
    cp "$dir/rootCA.pem" "$exported"
  fi
}

setup_ssh_key() {
  log "SSH key"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [[ ! -f "$HOME/.ssh/id_rsa" && ! -f "$HOME/.ssh/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C "$USER@$(hostname)"
    echo "Generated ~/.ssh/id_ed25519 - add the public key to GitHub before cloning repos."
  fi
}

copy_if_missing() {
  [[ -f "$1" && ! -e "$2" ]] || return 0
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
}

setup_reach_repos() {
  log "Reach repositories"
  if [[ ! -d "$REACH_BASE/.git" ]]; then
    if ! git clone -b "$REACH_DEVOPS_BRANCH" -c core.sshCommand="ssh -o StrictHostKeyChecking=accept-new" \
      "$REACH_DEVOPS_REPO" "$REACH_BASE" </dev/null; then
      echo "ERROR: could not clone $REACH_DEVOPS_REPO (is your SSH key on GitHub and loaded in ssh-agent?)" >&2
      exit 1
    fi
  fi

  local repo missing=false
  while read -r repo; do
    [[ -n "$repo" && ! -d "$REACH_DEV/repos/$repo" ]] && missing=true
  done <"$REACH_DEV/repos.txt"
  if [[ "$missing" == true ]]; then
    local input=/dev/null
    has_tty && input=/dev/tty
    (cd "$REACH_BASE" && "$REACH_BASE/bin/getRepos.sh" dev <"$input") || warn "getRepos.sh failed; re-run it from $REACH_BASE"
  fi

  copy_if_missing "$REACH_DEV/env.example" "$REACH_DEV/.env"
  copy_if_missing "$REACH_V2/config_local.sample.yaml" "$REACH_V2/config_local.yaml"
  copy_if_missing "$REACH_V2/.vscode/settings-example.json" "$REACH_V2/.vscode/settings.json"
  mkdir -p "$HOME/.config/Code/User"
}

# Everything runs from main so that, under `wget ... | bash`, bash has read the whole script before any
# command (ssh, apt, ...) can consume the rest of stdin.
main() {
  install_packages
  ensure_wsl_systemd
  [[ "$DEV" == true ]] && check_github_ssh
  install_ssm_plugin
  install_docker
  install_mise
  deploy_dotfiles
  setup_ssh_key
  if [[ "$DEV" == true ]]; then
    configure_hosts
    setup_reach_repos
    setup_mkcert
  fi
  if ((${#WARNINGS[@]})); then
    echo
    echo "Finished with warnings:" >&2
    printf '  - %s\n' "${WARNINGS[@]}" >&2
  fi
  log "Done. Open a new shell (docker group membership needs a re-login)."
  [[ "$DEV" == true ]] || log "Reach dev environment not installed; run again with --dev to add it."
}

main

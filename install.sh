#!/bin/bash
# Reach developer workstation bootstrap for Debian/Ubuntu (including WSL).
set -euo pipefail

SYSINIT_REPO=https://github.com/withreach/sysinit.git
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
  amazon-ecr-credential-helper awscli github-cli granted@0.38 jq mkcert
  pre-commit python@3.11 starship usage
)

log() { echo "==> $*"; }

[[ -r /etc/debian_version ]] || { echo "Debian/Ubuntu only" >&2; exit 1; }
[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not root" >&2; exit 1; }

install_packages() {
  log "System packages"
  sudo apt-get update
  sudo apt-get install -y bash-completion ca-certificates curl gcc git gnupg \
    libnss3-tools locales make postgresql-client rsync unzip xclip xsel zip
  sudo locale-gen en_US.UTF-8
}

install_ssm_plugin() {
  command -v session-manager-plugin >/dev/null && return
  log "AWS Session Manager plugin"
  local deb
  deb="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$deb" https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
  sudo apt-get install -y "$deb"
  rm -f "$deb"
}

install_docker() {
  log "Docker"
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
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  if [[ -d /run/systemd/system ]]; then
    sudo systemctl enable --now docker
  fi
}

install_mise() {
  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v mise >/dev/null; then
    log "mise"
    local dir
    dir="$(mktemp -d)"
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 0x7413A06D
    curl -fsSL https://mise.jdx.dev/install.sh.sig | gpg --decrypt >"$dir/install.sh"
    sh "$dir/install.sh"
    rm -rf "$dir"
  fi
  log "mise tools"
  mise use --global --yes "${MISE_TOOLS[@]}" || echo "WARNING: mise tool install failed (rate limit?); re-run later" >&2
}

git_identity() {
  GIT_USER_NAME="${GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || true)}"
  GIT_USER_EMAIL="${GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
  GIT_USER_NAME="${GIT_USER_NAME:-$USER}"
  GIT_USER_EMAIL="${GIT_USER_EMAIL:-$USER@$(hostname)}"
  echo "Git identity: $GIT_USER_NAME <$GIT_USER_EMAIL>"
}

deploy_dotfiles() {
  log "Dotfiles"
  local src
  src=""
  [[ -n "${BASH_SOURCE[0]:-}" ]] && src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -z "$src" || ! -d "$src/home" ]]; then
    src="$HOME/sysinit"
    if [[ -d "$src/.git" ]]; then
      git -C "$src" pull
    else
      git clone -b main --single-branch "$SYSINIT_REPO" "$src"
    fi
  fi

  git_identity
  cp -rT "$src/home" "$HOME"
  sed -i \
    -e "s|@GIT_USER_NAME@|${GIT_USER_NAME//&/\\&}|" \
    -e "s|@GIT_USER_EMAIL@|${GIT_USER_EMAIL//&/\\&}|" \
    "$HOME/.gitconfig"
  chmod 700 "$HOME/.profile.d"

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

configure_system() {
  log "sudoers and /etc/hosts"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Allow $USER to modify /etc/hosts without password for reach development
$USER ALL=(ALL) NOPASSWD: /usr/bin/tee -a /etc/hosts
$USER ALL=(ALL) NOPASSWD: /usr/bin/sed -i * /etc/hosts
EOF
  sudo visudo -cf "$tmp"
  sudo install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/$USER-reach"

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
    git clone -b "$REACH_DEVOPS_BRANCH" -c core.sshCommand="ssh -o StrictHostKeyChecking=accept-new" \
      "$REACH_DEVOPS_REPO" "$REACH_BASE" || {
      echo "WARNING: could not clone $REACH_DEVOPS_REPO (is your SSH key on GitHub and loaded in ssh-agent?)" >&2
      return 0
    }
  fi

  local repo missing=false
  while read -r repo; do
    [[ -n "$repo" && ! -d "$REACH_DEV/repos/$repo" ]] && missing=true
  done <"$REACH_DEV/repos.txt"
  if [[ "$missing" == true ]]; then
    (cd "$REACH_BASE" && "$REACH_BASE/bin/getRepos.sh" dev) || echo "WARNING: getRepos.sh failed" >&2
  fi

  copy_if_missing "$REACH_DEV/env.example" "$REACH_DEV/.env"
  copy_if_missing "$REACH_V2/config_local.sample.yaml" "$REACH_V2/config_local.yaml"
  copy_if_missing "$REACH_V2/.vscode/settings-example.json" "$REACH_V2/.vscode/settings.json"
  mkdir -p "$HOME/.config/Code/User"
}

install_packages
install_ssm_plugin
install_docker
install_mise
deploy_dotfiles
configure_system
setup_ssh_key
setup_reach_repos
log "Done. Open a new shell (docker group membership needs a re-login)."

#!/bin/bash

set -euo pipefail

SYSINIT_REPO=https://github.com/withreach/sysinit.git
script_dir="$HOME/sysinit"

# Global variables for tag management
USE_REACH=false
ANSIBLE_TAGS="system"
SKIP_SSH=false

# Show usage information
show_usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Options:
  --reach        Include reach-specific configuration (SSH, repos, etc.)
  --help, -h     Show this help message

Examples:
  # System only installation
  $0
  
  # System + reach installation  
  $0 --reach
  
  # Via wget (system only)
  wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash
  
  # Via wget with reach
  wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash -s -- --reach

Tags used:
  system - Core system packages and development tools
  reach  - Company-specific configuration (SSH, repos, sudo)
  wsl    - Automatically detected WSL-specific tools

EOF
}

# Parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --reach)
        USE_REACH=true
        shift
        ;;
      --help|-h)
        show_usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        show_usage
        exit 1
        ;;
    esac
  done
}

# Detect if running in WSL
detect_wsl() {
  if [[ -f /proc/version ]] && grep -qi microsoft /proc/version; then
    return 0  # WSL detected
  elif [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    return 0  # WSL detected via environment variable
  elif [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
    return 0  # WSL detected via interop file
  else
    return 1  # Not WSL
  fi
}

# Determine which ansible tags to use
determine_ansible_tags() {
  local tags=("system")
  
  # Add reach tag if requested
  if [[ "$USE_REACH" == "true" ]]; then
    tags+=("reach")
    SKIP_SSH=false
  else
    SKIP_SSH=true
  fi
  
  # Add wsl tag if detected
  if detect_wsl; then
    tags+=("wsl")
  fi
  
  # Join tags with comma
  ANSIBLE_TAGS=$(IFS=','; echo "${tags[*]}")
  
  echo "🏷️  Using ansible tags: $ANSIBLE_TAGS"
  if [[ "$SKIP_SSH" == "true" ]]; then
    echo "🔑 SSH setup will be skipped (system-only install)"
  fi
}

cleanup() {
  if command -v deactivate >/dev/null; then
    deactivate || true
  fi
  # Only clean up temp files, preserve .venv for idempotency
  rm -rf "${mise_installer:-/tmp}/mise_install.sh" || true
}
trap cleanup ERR EXIT

# Detect packages based on os type
get_packages_for_pm() {
  local pm="$1"
  case "$pm" in
  apt)
    echo "curl git gpg"
    ;;
  pacman)
    echo "curl git gnupg"
    ;;
  yum)
    echo "curl git gnupg2"
    ;;
  dnf)
    echo "curl git gnupg2 python3-libdnf5"
    ;;
  *)
    echo "curl git gnupg"
    ;;
  esac
}

# Detect package manager
get_package_manager() {
  declare -A os_info=(
    ["/etc/redhat-release"]="yum"
    ["/etc/arch-release"]="pacman"
    ["/etc/debian_version"]="apt"
    ["/etc/fedora-release"]="dnf"
  )
  for f in "${!os_info[@]}"; do
    if [[ -f "$f" ]]; then
      echo "${os_info[$f]}"
      return
    fi
  done
  echo "unknown"
}

# Install required packages
install_packages() {
  local pm
  pm=$(get_package_manager)
  local packages
  packages=$(get_packages_for_pm "$pm")

  case "$pm" in
  apt)
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y $packages
    sudo apt autoremove -y
    ;;
  dnf)
    sudo dnf update -y
    sudo dnf install -y $packages
    ;;
  pacman)
    sudo pacman -Syu --noconfirm
    sudo pacman -S --noconfirm $packages
    ;;
  yum)
    sudo yum update -y
    sudo yum install -y $packages
    ;;
  *)
    echo "Unsupported or unknown package manager"
    exit 1
    ;;
  esac
}

# Install mise and add
# mise to PATH and activate
install_mise() {
  # Check if mise is already installed
  if command -v "$HOME/.local/bin/mise" >/dev/null 2>&1; then
    echo "mise already installed, skipping installation"
    export PATH="$HOME/.local/bin:$PATH"
    eval "$("$HOME/.local/bin/mise" activate bash)"
    return
  fi

  mise_installer="$(mktemp -d)"
  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 0x7413A06D
  curl https://mise.jdx.dev/install.sh.sig | gpg --decrypt >"$mise_installer/mise_install.sh"
  sh "$mise_installer/mise_install.sh"
  export PATH="$HOME/.local/bin:$PATH"

  # Only add to bashrc if not already present
  if ! grep -q "mise activate bash" ~/.bashrc; then
    echo "eval \"\$($HOME/.local/bin/mise activate bash)\"" >>~/.bashrc
  fi
  eval "$("$HOME/.local/bin/mise" activate bash)"
}

# Clone or pull sysinit repo
sync_repo() {
  if [[ -d "$script_dir" ]]; then
    # @TODO: save users changes if any
    git -C "$script_dir" pull
  else
    git clone -b main --single-branch $SYSINIT_REPO "$script_dir"
  fi
}

# Setup and activate virtual environment
# Install required dependencies
setup_python_env() {
  cd "$script_dir"

  # Ensure mise is in PATH and activated
  export PATH="$HOME/.local/bin:$PATH"
  if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
  else
    echo "Error: mise not found in PATH"
    exit 1
  fi

  mise trust -a
  mise use --global uv
  eval "$(mise activate bash)"
  export PATH="$HOME/.local/share/mise/shims:$PATH"
  sleep 2
  mise reshim

  # Only create venv if it doesn't exist or if sysinit package isn't installed
  if [[ ! -d ".venv" ]] || ! .venv/bin/python -c "import sysinit" 2>/dev/null; then
    uv venv --clear
    # shellcheck disable=SC1091
    source ".venv/bin/activate"
    uv pip install -e .
  else
    # shellcheck disable=SC1091
    source ".venv/bin/activate"
  fi
}

# Run ansible playbook
run_ansible() {
  echo "🚀 Running ansible playbook with tags: $ANSIBLE_TAGS"
  ansible-playbook playbook.yml \
    -K \
    -t "$ANSIBLE_TAGS" \
    -e "git_user_name=${GIT_USER_NAME}" \
    -e "git_user_email=${GIT_USER_EMAIL}"
}

# Check and collect required Git configuration
setup_git_config() {
  # Check for environment variables first
  GIT_USER_NAME="${GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || true)}"
  GIT_USER_EMAIL="${GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"

  # Use default values if still empty instead of prompting
  if [ -z "$GIT_USER_NAME" ]; then
    GIT_USER_NAME="${USER:-$(whoami)}"
  fi

  if [ -z "$GIT_USER_EMAIL" ]; then
    local hostname=$(hostname 2>/dev/null || echo "localhost")
    GIT_USER_EMAIL="${USER:-$(whoami)}@${hostname}"
  fi

  echo "Git configuration: $GIT_USER_NAME <$GIT_USER_EMAIL>"

  # Export for use in ansible
  export GIT_USER_NAME
  export GIT_USER_EMAIL
}

# Setup SSH agent for GitHub access
# Setup SSH agent for GitHub access
setup_ssh_agent() {
  local ssh_env="$HOME/.ssh/agent-env"
  local existing_agent=false
  local keys_loaded=false
  local is_interactive=false

  # Check if we have an interactive terminal
  if [ -t 0 ] && [ -t 1 ]; then
    is_interactive=true
  fi

  echo "🔑 Setting up SSH agent and keys..."

  # Ensure .ssh directory exists
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # Check if there's already a working SSH agent with keys
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_AGENT_PID:-}" ]; then
    if kill -0 "$SSH_AGENT_PID" 2>/dev/null && ssh-add -l >/dev/null 2>&1; then
      echo "✅ Found existing SSH agent with keys loaded, using it"
      echo "   Keys loaded: $(ssh-add -l | wc -l)"
      export SSH_AUTH_SOCK
      export SSH_AGENT_PID
      return 0
    fi
  fi

  # If no existing agent, check if we have one saved in agent-env
  if [ "$existing_agent" = false ] && [ -f "$ssh_env" ]; then
    # shellcheck source=/dev/null
    source "$ssh_env" >/dev/null 2>&1 || true
    if [ -n "${SSH_AGENT_PID:-}" ] && kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
      if ssh-add -l >/dev/null 2>&1; then
        echo "✅ Found existing SSH agent in $ssh_env with keys loaded"
        echo "   Keys loaded: $(ssh-add -l | wc -l)"
        existing_agent=true
        keys_loaded=true
      else
        echo "📋 Found existing SSH agent in $ssh_env but no keys loaded"
        existing_agent=true
      fi
    fi
  fi

  # Start new agent only if we don't have a working one
  if [ "$existing_agent" = false ]; then
    echo "🚀 Starting new SSH agent..."
    # Kill any stale agents first
    if [ -f "$ssh_env" ]; then
      # shellcheck source=/dev/null
      source "$ssh_env" >/dev/null 2>&1 || true
      if [ -n "${SSH_AGENT_PID:-}" ] && kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
        kill "$SSH_AGENT_PID" 2>/dev/null || true
      fi
    fi

    ssh-agent >"$ssh_env"
    chmod 600 "$ssh_env"
    # shellcheck disable=SC1090
    source "$ssh_env" >/dev/null

    # Verify agent is running
    if [ -z "${SSH_AGENT_PID:-}" ] || ! kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
      echo "❌ Error: Failed to start SSH agent"
      exit 1
    fi
    echo "✅ SSH agent started successfully"
  fi

  # If we don't have keys loaded, try to load them
  if [ "$keys_loaded" = false ]; then
    echo "🔍 Looking for SSH keys to load..."
    
    # Look for SSH keys to add
    local keys_found=false
    local keys_added=false
    local found_encrypted=false

    for key in ~/.ssh/id_rsa ~/.ssh/id_ed25519 ~/.ssh/id_ecdsa ~/.ssh/id_dsa; do
      if [ -f "$key" ]; then
        keys_found=true
        echo "   Found SSH key: $key"

        # First try without passphrase (for unencrypted keys)
        if ssh-add "$key" 2>/dev/null; then
          echo "   ✅ Successfully added $key (no passphrase required)"
          keys_added=true
          break
        else
          # Check if key is encrypted by trying to read it
          if ssh-keygen -y -f "$key" >/dev/null 2>&1; then
            echo "   ⚠️  Key $key is not encrypted but failed to load"
          else
            found_encrypted=true
            echo "   🔐 Key $key appears to be encrypted"
            
            # If we have an interactive terminal, try to prompt for passphrase
            if [ "$is_interactive" = true ]; then
              echo "   🔑 Prompting for passphrase..."
              if ssh-add "$key"; then
                echo "   ✅ Successfully added $key with passphrase"
                keys_added=true
                break
              else
                echo "   ❌ Failed to add $key even with passphrase"
              fi
            else
              echo "   ⏸️  Cannot prompt for passphrase (no interactive terminal)"
            fi
          fi
        fi
      fi
    done

    # Handle the case where no keys were found
    if [ "$keys_found" = false ]; then
      echo ""
      echo "❌ No SSH keys found in ~/.ssh/"
      echo ""
      echo "📝 To fix this, generate an SSH key pair:"
      echo "   ssh-keygen -t ed25519 -C \"your-email@example.com\""
      echo ""
      echo "Then run this script again."
      echo ""
      exit 1
    fi

    # Handle the case where keys were found but none could be loaded
    if [ "$keys_added" = false ]; then
      echo ""
      if [ "$is_interactive" = true ]; then
        echo "❌ Could not load any SSH keys, even with interactive prompts."
        echo ""
        echo "This might be due to:"
        echo "   • Invalid or corrupted key files"  
        echo "   • Permission issues"
        echo "   • Incorrect passphrase"
        echo ""
        echo "🔧 Try these troubleshooting steps:"
        echo "   1. Check key permissions: ls -la ~/.ssh/"
        echo "   2. Test key manually: ssh-add ~/.ssh/id_rsa"
        echo "   3. Verify key format: ssh-keygen -l -f ~/.ssh/id_rsa"
        echo ""
        exit 1
      else
        echo "⚠️  SSH keys found but require manual loading (no interactive terminal available)"
        echo ""
        echo "🎯 SOLUTION: Choose one of these options:"
        echo ""
        echo "Option 1 - Pre-load your SSH key, then re-run:"
        echo "   # Load your SSH key first"
        if [ -f "$ssh_env" ]; then
          echo "   source $ssh_env"
        else
          echo "   eval \$(ssh-agent -s)"
        fi
        echo "   ssh-add ~/.ssh/id_rsa  # (or your key file)"
        echo "   # Then re-run the installer"
        echo "   wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash"
        echo ""
        echo "Option 2 - Run the script interactively:"
        echo "   # Download and run interactively"
        echo "   wget https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh"
        echo "   chmod +x install.sh"
        echo "   ./install.sh"
        echo ""
        echo "Option 3 - Use an unencrypted key (less secure):"
        echo "   ssh-keygen -t ed25519 -f ~/.ssh/id_sysinit -N \"\""
        echo "   # Then re-run this script"
        echo ""
        echo "💡 For security, Option 1 or 2 are recommended."
        echo ""
        exit 1
      fi
    fi
  fi

  # Final verification that we have working SSH keys
  if ! ssh-add -l >/dev/null 2>&1; then
    echo "❌ Error: SSH agent is running but no keys are loaded"
    exit 1
  fi

  echo "✅ SSH agent setup complete!"
  echo "   🔑 Keys loaded: $(ssh-add -l | wc -l)"
  echo "   📋 Agent PID: $SSH_AGENT_PID"

  # Export environment for Ansible
  export SSH_AUTH_SOCK
  export SSH_AGENT_PID
}


# Main execution with better error handling
main() {
  # Parse command line arguments
  parse_arguments "$@"
  
  # Determine which tags to use
  determine_ansible_tags
  
  install_packages
  install_mise
  sync_repo
  setup_git_config
  
  # Skip SSH setup if not needed for reach configuration
  if [[ "$SKIP_SSH" != "true" ]]; then
    setup_ssh_agent
  fi
  
  setup_python_env
  run_ansible
}

# Run main function
main "$@"

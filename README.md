# Linux System Initialization

An opinionated script to initialize your Linux system.

## Distros

This release has been tested on the following distributions, and should work on all distros based from:

- Arch
- CentOS
- Debian
- Fedora
- Ubuntu

## Prerequisites (Mandatory)

Before running the installer, ensure you have:

- **Sudo privileges** on the machine
- **Git identity configured globally**:
  ```bash
  git config --global user.name "Your Name"
  git config --global user.email "you@example.com"
  ```
  *Why: The installer passes your Git identity into the Ansible role and will fail if not provided. It will prompt if missing, but will exit if you leave either value blank.*

- **An SSH key present and loadable by ssh-agent**:
  - Recommended to use ed25519 keys
  - Check for an existing key:
    ```bash
    ls ~/.ssh/id_ed25519 ~/.ssh/id_rsa
    ```
  - If you don't have one, generate a key:
    ```bash
    ssh-keygen -t ed25519 -C "your_email@example.com"
    ```
  - Add it to your agent (if needed):
    ```bash
    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_ed25519
    ```
  *Why: The installer needs SSH access to clone private repositories. If no usable key is found, it exits with instructions to generate one.*

- **Network access** to download dependencies (curl/wget, gpg/gnupg will be installed as needed)
- **Python 3.11+** (the project targets Python >= 3.11)

## Quick Start

Open a terminal and run:

```bash
wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash
```

Alternatively if you want to audit the script clone the repo, and run the install.sh script:

```bash
git clone https://github.com/withreach/sysinit.git
cd sysinit
./install.sh
```

## Usage

**Option 1: One-liner (audited remotely)**
```bash
wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash
```

Optionally, pre-set your Git identity via environment variables to skip prompts:
```bash
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="you@example.com"
wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash
```

**Option 2: Clone locally, review, then run**
```bash
git clone https://github.com/withreach/sysinit.git
cd sysinit
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="you@example.com"
./install.sh
```

**Option 3: Run Ansible directly (manual, for advanced users)**

The installer bootstraps tooling and a virtual environment for you; if you prefer, you can run the playbook directly:
- Ensure Python 3.11+ and dependencies are installed (uv/mise steps are handled by install.sh)
- Pass Git identity to the playbook (required):
  ```bash
  ansible-playbook playbook.yml -K -e "git_user_name=Your Name" -e "git_user_email=you@example.com"
  ```

**Notes:**
- The installer will start an ssh-agent and attempt to load a default SSH key (id_ed25519, id_rsa). If none are found or loadable, it exits with guidance.
- The playbook targets localhost by default and will ask for sudo (-K) to perform system changes.

## Troubleshooting

**No SSH keys found:**
Generate an ed25519 key:
```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```
Then re-run the installer.

**SSH keys could not be loaded:**
If your key is encrypted, run:
```bash
source ~/.ssh/agent-env
ssh-add ~/.ssh/id_ed25519
```
Then re-run the installer.

**Missing Git identity:**
Set both values globally:
```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```
Or export environment variables before running:
```bash
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="you@example.com"
```

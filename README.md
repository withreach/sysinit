# System Initialization

Opinionated bootstrap scripts for initializing Linux and Windows developer workstations.

## Supported Platforms

### Linux

Tested on:

* Arch
* CentOS
* Debian
* Fedora
* Ubuntu

The installer should also work on most distributions derived from these families.

### Windows

Tested on:

* Windows 11
* Windows 10

The installer configures:

* Git
* AWS CLI
* AWS Session Manager Plugin
* mkcert
* WSL2
* A Linux distribution running Reach sysinit inside WSL

---

# Linux Installation

## Prerequisites

Before running the installer, ensure you have:

### Sudo privileges

The installer performs system-level changes and requires sudo access.

### Git identity configured

Configure Git globally:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

or provide values using environment variables:

```bash
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="you@example.com"
```

The installer passes your Git identity into the Ansible roles and will fail if neither method is provided.

### SSH key available

The installer requires SSH access to clone private repositories.

Check for an existing key:

```bash
ls ~/.ssh/id_ed25519 ~/.ssh/id_rsa
```

Generate one if necessary:

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

Load the key into your agent:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

---

## Installation Methods

### Option 1 — Remote one-line install

Using wget:

```bash
wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash
```

Using curl:

```bash
curl -sSL https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash
```

### Option 2 — Clone locally and review

```bash
git clone https://github.com/withreach/sysinit.git
cd sysinit
./install.sh
```

### Option 3 — Run Ansible directly

For advanced users who prefer to manage dependencies manually.

Install dependencies:

```bash
pip install -r requirements.txt
ansible-galaxy install -r requirements.yml
```

Run the playbook:

```bash
ansible-playbook -i inventory/hosts.yml playbook.yml -K
```

---

## Configuration Options

### Install Reach components

```bash
ansible-playbook playbook.yml -e "install_reach=true"
```

or:

```bash
./install.sh --extra-vars "install_reach=true"
```

By default:

```text
install_reach=false
```

Set it to `true` to include Reach components during installation.

---

# Windows Installation

Open **PowerShell as Administrator** before running any commands.

## Installation Methods

### Option 1 — Default installation

Installs:

* Git
* AWS CLI
* AWS Session Manager Plugin
* mkcert
* WSL2
* Ubuntu 24.04
* Reach sysinit inside WSL

```powershell
irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1 | iex
```

### Option 2 — Install with optional developer applications

Also installs:

* Visual Studio Code
* Slack
* Postman
* Meld

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) -InstallExtras
```

### Option 3 — Install with SSH key synchronization

Copies Windows SSH keys into WSL.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) -SyncSSHKeys
```

### Option 4 — Install using a different WSL distribution

Example using Debian:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) `
    -WSLDistro Debian
```

### Option 5 — Install using a custom distro name

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) `
    -DistroName dev-linux
```

### Option 6 — Full installation example

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) `
    -InstallExtras `
    -SyncSSHKeys `
    -WSLDistro Ubuntu-24.04 `
    -DistroName rch-dev
```

### Option 7 — Clone locally and review

```powershell
git clone https://github.com/withreach/sysinit.git
cd sysinit
.\install.ps1 -InstallExtras -SyncSSHKeys
```

---

# Development

This project uses Task for automation.

Install development dependencies:

```bash
task install-deps
```

Install pre-commit hooks:

```bash
task install-hooks
```

View available tasks:

```bash
task --list-all
```

Run linting:

```bash
task lint
```

Run tests:

```bash
task molecule-test
```

## Available Development Commands

| Command                  | Description                     |
| ------------------------ | ------------------------------- |
| `task lint`              | Run all linters                 |
| `task syntax-check`      | Validate Ansible syntax         |
| `task molecule-test`     | Run the full Molecule suite     |
| `task molecule-converge` | Quick converge for development  |
| `task scan-secrets`      | Scan the repository for secrets |
| `task clean`             | Remove build artifacts          |

---

## Notes

### Linux

* The installer starts `ssh-agent` automatically if required.
* It attempts to load `id_ed25519` and `id_rsa`.
* If no usable key is available, installation stops with instructions.

### Windows

* The installer must be executed from an elevated PowerShell session.
* SSH key synchronization is disabled by default.
* The default WSL distribution is `Ubuntu-24.04`.
* The default WSL instance name is `rch-ubuntu`.

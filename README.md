# System Initialization

Bootstrap scripts for Reach developer workstations: Windows (installs WSL2) and Debian/Ubuntu (including WSL).

## Linux (Debian/Ubuntu)

Requires sudo and an SSH key on GitHub (loaded in your agent) for cloning private repos. Optionally set `GIT_USER_NAME` / `GIT_USER_EMAIL`; otherwise your global git config is used.

```bash
wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash
```

or review first:

```bash
git clone https://github.com/withreach/sysinit.git
cd sysinit
./install.sh
```

It installs system packages, the AWS SSM plugin, Docker and mise (with the tools listed in `install.sh`), deploys the dotfiles in `home/`, configures sudoers and `/etc/hosts` for `*.rch.local`, generates an SSH key if none exists, and clones the reach-devops repos. Re-running is safe; `.env`, `config_local.yaml` and VS Code settings are only created if missing.

---

# Windows Installation

Open **PowerShell as Administrator** before running any commands.

If a reboot is needed, the script schedules itself to resume after you log in and restarts the machine after 30 seconds (cancel with `shutdown /a`).

## Installation Methods

### Option 1 — Default installation

Installs mkcert, WSL2 and Ubuntu 24.04 (instance `rch-ubuntu`), runs `install.sh` inside it, trusts the mkcert CA and adds the Reach hosts entries.

```powershell
irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1 | iex
```

### Option 2 — Install with SSH key synchronization

Copies Windows SSH keys into WSL.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) -SyncSSHKeys
```

### Option 3 — Install using a different WSL distribution (Debian/Ubuntu only)

Example using Debian:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) `
    -WSLDistro Debian
```

### Option 4 — Clone locally and review

```powershell
git clone https://github.com/withreach/sysinit.git
cd sysinit
.\install.ps1 -SyncSSHKeys
```

---

# Development

```bash
task install:hooks   # pre-commit hooks
task lint            # shellcheck
task check           # all pre-commit checks
```

Notes: the Windows installer must run from an elevated PowerShell; SSH key sync is off by default; the WSL instance is named `rch-<distro>` (e.g. `rch-ubuntu`).

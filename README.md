# System Initialization

Bootstrap scripts for Reach developer workstations: Windows (installs WSL2) and Debian/Ubuntu (including WSL).

## Linux (Debian/Ubuntu)

Requires sudo. Optionally set `GIT_USER_NAME` / `GIT_USER_EMAIL`; otherwise your global git config is used.

The install has two parts:

* **Base** (default): system packages, AWS SSM plugin, Docker, mise and its tools, dotfiles in `home/`, and an SSH key (generated if you have none).
* **Reach dev environment** (`--dev`): sudoers and `/etc/hosts` entries for `*.rch.local`, the reach-devops clone, `getRepos.sh`, and the `.env`, `config_local.yaml` and VS Code settings. This needs an SSH key on GitHub, loaded in your agent.

```bash
wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash
```

Add the dev environment now or later (safe to re-run; config files are only created if missing):

```bash
wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash -s -- --dev
~/sysinit/install.sh --dev
```

or review first:

```bash
git clone https://github.com/withreach/sysinit.git
cd sysinit
./install.sh        # base; add --dev for the Reach dev environment
```

---

# Windows Installation

Open **PowerShell as Administrator** before running any commands.

If a reboot is needed, the script schedules itself to resume after you log in and restarts the machine after 10 seconds (cancel with `shutdown /a`).

## Installation Methods

### Option 1 — Default installation

Installs WSL2 and Ubuntu 24.04 (instance `rch-ubuntu`) and runs the base `install.sh` inside it.

```powershell
irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1 | iex
```

### Option 2 — Include the Reach dev environment

Also runs `install.sh --dev` in WSL, installs mkcert and trusts its CA on Windows, and adds the `rch.local` hosts entries.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) -Dev
```

### Option 3 — Install your SSH key into WSL

Pass the path to your private key (ed25519 or RSA, any filename). It is installed in WSL as `~/.ssh/id_ed25519` or `~/.ssh/id_rsa` with a matching `.pub`, whatever your Windows and Linux usernames are. If the key has a passphrase you are prompted for it once. Without `-SSHKey`, nothing is copied.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) `
    -SSHKey C:\Users\you\.ssh\id_rsa.pem
```

### Option 4 — Install using a different WSL distribution (Debian/Ubuntu only)

Example using Debian:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) `
    -WSLDistro Debian
```

### Option 5 — Clone locally and review

```powershell
git clone https://github.com/withreach/sysinit.git
cd sysinit
.\install.ps1 -SSHKey C:\Users\you\.ssh\id_ed25519
```

---

# Development

Install [pre-commit](https://pre-commit.com), [shellcheck](https://www.shellcheck.net) and [Task](https://taskfile.dev), then:

```bash
task install:hooks   # pre-commit hooks (whitespace/YAML checks, shellcheck)
task lint            # shellcheck
task check           # all pre-commit checks
```

## Layout

- `install.sh` - Debian/Ubuntu bootstrap (packages, Docker, mise, dotfiles, Reach setup)
- `home/` - dotfiles copied into `$HOME`; `@GIT_USER_NAME@` / `@GIT_USER_EMAIL@` in `.gitconfig` are substituted by `install.sh`
- `install.ps1` - Windows bootstrap (WSL2, mkcert, hosts)

## Testing

Run `install.sh` in a throwaway Debian/Ubuntu container or WSL instance, and run it twice to confirm it is idempotent. Run `task lint` before opening a PR.

## Notes

The Windows installer must run from an elevated PowerShell; the WSL instance is named `rch-<distro>` (e.g. `rch-ubuntu`).

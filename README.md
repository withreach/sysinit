# System Initialization

Bootstrap scripts for Reach developer workstations: Windows (installs WSL2) and Debian/Ubuntu (including WSL).

## Linux (Debian/Ubuntu)

Requires sudo. Supports x86-64 and ARM64. Optional environment variables:

* `GIT_USER_NAME` / `GIT_USER_EMAIL`: your git identity. Otherwise your global git config is used, or you are asked.
* `SYSINIT_REF`: the sysinit branch or tag whose dotfiles are deployed (default `main`).
* `SYSINIT_WIN_CAROOT`: an mkcert CA directory to copy into `~/.local/share/mkcert`, where reach-devops' certificate generator expects it. The Windows installer passes the Windows CA, so the `*.rch.local` certificate is trusted on both sides.

The install has two parts:

* **Base** (default): system packages, AWS SSM plugin, Docker (skipped if Docker Desktop's WSL integration is on), mise and its tools, dotfiles in `home/`, git settings, and an SSH key (generated if you have none).
* **Reach dev environment** (`--dev`): `/etc/hosts` entries for `*.rch.local` (not on WSL, which copies them from the Windows hosts file), the mkcert CA in `~/.local/share/mkcert` (trusted in Linux; `httpd/ssl.crt` is removed for regeneration if another CA signed it), the reach-devops clone, `getRepos.sh`, and the `.env`, `config_local.yaml` and VS Code settings. This needs an SSH key on GitHub, loaded in your agent.

Re-running is safe. Files in `.profile.d/` and `~/.config/git/sysinit.gitconfig` are refreshed each time; other dotfiles (`~/.aws/config`, `~/.docker/config.json`, `~/.psqlrc`, ...) and the Reach config files are only created if missing, so your edits are kept. `~/.gitconfig` is yours: it includes `sysinit.gitconfig` first, so anything you set there wins.

On WSL, if systemd is not enabled the script enables it in `/etc/wsl.conf` and asks you to restart the instance (`wsl --terminate <name>`) and re-run.

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

Open a **regular (non-admin) PowerShell** as your own Windows user. WSL distros are per user, so running "as Administrator" with a separate admin account would install WSL for that account only. The script asks for Administrator rights (UAC) just for the machine-wide steps: Windows features, updating WSL (`wsl --update --web-download`, no Microsoft Store needed), mkcert and the hosts file. If that step fails, its log is in `C:\ProgramData\ReachSysinit\admin.log`.

What it asks you for:

* Your git name and email, unless they are already in your Windows git config.
* For a new distro: a Linux username (defaults to your Windows username) and its password, used for `sudo`.
* A passphrase, if the `-SSHKey` key has one.

On Windows 11 it creates `%USERPROFILE%\.wslconfig` with mirrored networking and DNS tunneling, which avoids most VPN and proxy problems; an existing `.wslconfig` is left alone.

If a reboot is needed, the script schedules itself to resume after you log in, then asks before restarting (the restart waits 30 seconds; cancel with `shutdown /a`).

Every option below takes `-Ref <branch-or-tag>` to install a specific version of sysinit instead of `main`.

## Installation Methods

### Option 1 — Default installation

Installs WSL2 and Ubuntu 24.04 (instance `rch-ubuntu`) and runs the base `install.sh` inside it.

```powershell
irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1 | iex
```

### Option 2 — Include the Reach dev environment

Also runs `install.sh --dev` in WSL, installs mkcert and trusts its CA on Windows, and adds the `rch.local` hosts entries. The Windows mkcert CA is copied into WSL (`~/.local/share/mkcert`), so the `*.rch.local` certificate reach-devops generates there is trusted by Windows browsers, with no manual CA copying.

The Reach repositories are private and cloned over SSH, so WSL needs a key registered with your GitHub account; the install stops early if GitHub rejects it. Pass `-SSHKey` (see Option 3) to copy your key in, or omit it if the key is already in `~/.ssh` in WSL.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) `
    -Dev -SSHKey C:\Users\you\.ssh\id_ed25519
```

### Option 3 — Install your SSH key into WSL

Pass the path to your private key (ed25519 or RSA, any filename). It is installed in WSL as `~/.ssh/id_ed25519` or `~/.ssh/id_rsa` with a matching `.pub`, whatever your Windows and Linux usernames are. A different key already at that path is kept as `id_*.bak-<timestamp>`. If the key has a passphrase you are prompted for it once. Without `-SSHKey`, nothing is copied.

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

### Option 5 — Choose the WSL instance name

The instance is named `rch-<distro>` (`rch-ubuntu`, `rch-debian`) by default; an instance with that name that already exists is reused. Pass `-WSLName` (letters, digits, `.`, `_`, `-`) to create additional, independent installs:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) `
    -WSLName rch-feature-x -Dev
```

### Option 6 — Clone locally and review

Run from a clone, the script uses the `install.sh` and dotfiles from that clone, so what you reviewed is what runs.

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
- `home/` - dotfiles copied into `$HOME`; `.profile.d/*` and `.config/git/sysinit.gitconfig` are overwritten on each run, everything else only if missing
- `install.ps1` - Windows bootstrap (WSL2, WSL user and config, mkcert, hosts)

## Testing

Run `install.sh` in a throwaway Debian/Ubuntu container or WSL instance, and run it twice to confirm it is idempotent. Run `task lint` before opening a PR.

## Notes

Run the Windows installer from a regular (non-admin) PowerShell; it asks for elevation only for the machine-wide steps. The WSL instance is named `rch-<distro>` (e.g. `rch-ubuntu`).

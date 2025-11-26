# Sysinit Tags Usage Guide

This sysinit role uses a simple three-tag system for easy management:

## Available Tags

### 🖥️ `system`
Core system setup and development tools:
- System packages installation
- Basic development tools: mise, docker, aws-ssm  
- Applications: chrome, dbeaver, opass, postman, slack
- Windows tools: gsudo

### 🏢 `reach`  
Company-specific configuration:
- SSH configuration
- Repository setup
- Sudo access configuration
- Host configuration
- SELinux configuration
- User preferences
- SSL certificates

### 🐧 `wsl`
WSL-specific configuration and tools:
- /etc/wsl.conf configuration
- usbipd-win installation (Windows host)
- usbip tools installation (Linux side)
- wsl-open installation

## Usage Examples

```bash
# Install only system tools
ansible-playbook -t system playbook.yml

# Install only reach configuration  
ansible-playbook -t reach playbook.yml

# Install only WSL tools
ansible-playbook -t wsl playbook.yml

# Install system + reach (skip WSL)
ansible-playbook -t system,reach playbook.yml

# Install everything
ansible-playbook playbook.yml

# Install specific tools within system
ansible-playbook -t system -e tools=docker,mise playbook.yml
```

## Tool Categories

| Tag | Tools |
|-----|-------|
| `system` | mise, docker, aws-ssm, chrome, dbeaver, opass, postman, slack, gsudo |
| `reach` | ssh, repos, sudoers, host, selinux, user, ssl-certs |
| `wsl` | wsl.conf, usbipd-win, usbip, wsl-open |

## Notes

- The `always` tag runs basic setup tasks regardless of which tags you specify
- System packages are installed with the `system` tag
- All tags are mutually exclusive - you can run any combination
- Use `-e tools=toolname` to install specific tools within a category
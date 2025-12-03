# Sysinit Role

An Ansible role for system initialization and development environment configuration.

## Requirements

- Ansible >= 11.8.0
- SSH key configured for Git operations (`~/.ssh/id_rsa`) or (`~/.ssh/id_ed25519`)
- Git configured with global user.name and user.email
- Sudo privileges for host file modifications
- Python 3 and pip3 for pre-commit installation

## Supported Platforms

- Debian
- Ubuntu
- Fedora
- CentOs
- Arch

## Role Variables

All variables are defined in `defaults/main.yml` and can be overridden:


## Dependencies

This role has no external role dependencies but requires the following Ansible collections:
- `ansible.posix`
- `community.general`
- `community.docker` (if using Docker-related tasks)

## Usage Example

### Basic Playbook
```yaml
---
- name: Initialize Development Environment
  hosts: localhost
  become: yes
  roles:
    - sysinit
```

### Command Line Usage
```bash
# Run the full role
ansible-playbook -i inventory playbook.yml

# Run specific tool installation
ansible-playbook -i inventory playbook.yml -e tools='chrome dbeaver'

# Check mode (dry run)
ansible-playbook -i inventory playbook.yml --check

# Provide Git identity to the playbook
ansible-playbook -i inventory playbook.yml -K -e "git_user_name=Your Name" -e "git_user_email=you@example.com"
```

**Note:** If you use the top-level `install.sh`, you can instead export:
```bash
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="you@example.com"
```
The installer will pass these values into Ansible for you.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with distributions
5. Submit a pull request

### Directory Configuration
```yaml
# Base directory for withreach development
withreach_dir: "{{ lookup('env','HOME') }}/withreach"

# Development repositories location
dev_repos_dir: "{{ withreach_dir }}/dev/repos"
v2_dir: "{{ dev_repos_dir }}/v2"

```

### Repository Configuration
```yaml
# Main DevOps repository
devops_repo: "git@github.com:withreach/reach-devops.git"

# Repository management script
repo_script: "{{ withreach_dir }}/bin/getRepos.sh"
```

### Configuration Files
```yaml
# VS Code settings
vscode_settings_example: "{{ v2_dir }}/.vscode/settings-example.json"
vscode_settings: "{{ v2_dir }}/.vscode/settings.json"

# Environment files
env_example: "{{ withreach_dir }}/dev/env.example"
env_file: "{{ withreach_dir }}/dev/.env"

# Local configuration
config_local_sample: "{{ v2_dir }}/config_local.sample.yaml"
config_local: "{{ v2_dir }}/config_local.yaml"
```

### Host Configuration
```yaml
# Marker for development hosts in /etc/hosts
hosts_marker: "# Local Development"

# List of development hosts to add
dev_hosts:
  - admin.rch.local
  - admin-api.rch.local
  - checkout.rch.local
  - portal.rch.local
  - reports.rch.local
  - stash.rch.local
  - redirect.rch.local
```

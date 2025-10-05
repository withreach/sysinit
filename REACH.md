# Reach

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
#!/usr/bin/env bash
# Reuse one ssh-agent across shells and load the default key (interactive shells only)
# shellcheck disable=SC1090
[[ $- == *i* ]] || return 0
[[ -f $HOME/.ssh/id_ed25519 || -f $HOME/.ssh/id_rsa ]] || return 0

_ssh_env="$HOME/.ssh/agent-env"

# ssh-add -l: 0 = keys loaded, 1 = agent without keys, 2 = no agent
ssh-add -l >/dev/null 2>&1
_rc=$?
if [[ $_rc -eq 2 ]]; then
  [[ -f $_ssh_env ]] && source "$_ssh_env" >/dev/null
  ssh-add -l >/dev/null 2>&1
  _rc=$?
  if [[ $_rc -eq 2 ]]; then
    ssh-agent -s >"$_ssh_env"
    chmod 600 "$_ssh_env"
    source "$_ssh_env" >/dev/null
    _rc=1
  fi
fi
[[ $_rc -eq 1 ]] && ssh-add 2>/dev/null

unset _ssh_env _rc

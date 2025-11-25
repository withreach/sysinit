#!/usr/bin/env bash

# Detect WSL
is_wsl=false
if grep -qi "microsoft" /proc/version 2>/dev/null; then
  is_wsl=true
fi

if [ "$is_wsl" = true ] && [ -f "$HOME/.wsl-init" ]; then
  bash "$HOME/.wsl-init" >/dev/null 2>&1 &
fi

SSH_ENV="$HOME/.ssh/agent-environment"

start_agent() {
  /usr/bin/ssh-agent | sed 's/^echo/#echo/' >"$SSH_ENV"
  chmod 600 "$SSH_ENV"
  . "$SSH_ENV" >/dev/null 2>&1
  ssh-add >/dev/null 2>&1
}

if [ -f "$SSH_ENV" ]; then
  . "$SSH_ENV" >/dev/null 2>&1
  # respawn agent if dead
  if ! ps -p "$SSH_AGENT_PID" >/dev/null 2>&1; then
    start_agent
  fi
else
  start_agent
fi

if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi

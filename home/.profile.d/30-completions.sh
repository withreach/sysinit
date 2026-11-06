#!/usr/bin/env bash
# git and docker completions ship with their packages and load lazily via bash-completion

[[ -f /etc/bash_completion ]] && source /etc/bash_completion

command -v aws_completer >/dev/null && complete -C aws_completer aws

if command -v starship >/dev/null; then
  export STARSHIP_CONFIG="$HOME/.config/starship.toml"
  eval "$(starship init bash)"
fi

#!/usr/bin/env bash
[[ $- == *i* ]] || return 0

if command -v starship >/dev/null; then
  export STARSHIP_CONFIG="$HOME/.config/starship.toml"
  eval "$(starship init bash)"
fi

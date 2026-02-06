#!/usr/bin/env bash

[ -f $(which aws_completer) ] && complete -C "$(which aws_completer)" aws

[ -f /etc/bash_completion ] && source /etc/bash_completion

[ -f "$HOME/.local/share/bash-completion/completions/docker" ] && source "$HOME/.local/share/bash-completion/completions/docker"

[ -f "$HOME/.local/share/bash-completion/completions/git-completion.bash" ] && source "$HOME/.local/share/bash-completion/completions/git-completion.bash"

#!/usr/bin/env bash

bash_completions_dir=$HOME/.local/share/bash-completions/completions

[[ -f $(which aws_completer) ]] && complete -C "aws_completer" aws

[[ -f $(which starship) ]] && eval "$(starship init bash)"

[[ -f /etc/bash_completion ]] && source /etc/bash_completion

[[ -f $bash_completions_dir/docker ]] && source $bash_completions_dir/docker

[[ -f $bash_completions_dir/git-completion.bash ]] && source $bash_completions_dir/git-completion.bash
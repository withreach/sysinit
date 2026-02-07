#!/usr/bin/env bash

path_add() {
  case ":$PATH:" in
    *":$1:"*) ;; # already in path
    *) PATH="$1:$PATH" ;;
  esac
}

path_add "$HOME/.local/bin"

export PATH
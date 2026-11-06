#!/usr/bin/env bash
# Put mise-managed tools (aws, starship, granted, ...) on PATH
command -v mise >/dev/null && eval "$(mise activate bash)"

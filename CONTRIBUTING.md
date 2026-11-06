# Contributing to sysinit

## Setup

Install [pre-commit](https://pre-commit.com), [shellcheck](https://www.shellcheck.net) and [Task](https://taskfile.dev), then:

```bash
task install:hooks
```

Hooks run on commit: whitespace/YAML checks, secret detection (`detect-secrets`, baseline in `.secrets.baseline`) and shellcheck.

## Layout

- `install.sh` - Debian/Ubuntu bootstrap (packages, Docker, mise, dotfiles, Reach setup)
- `home/` - dotfiles copied into `$HOME`; `@GIT_USER_NAME@` / `@GIT_USER_EMAIL@` in `.gitconfig` are substituted by `install.sh`
- `install.ps1` - Windows bootstrap (WSL2, mkcert, hosts)

## Testing

Run `install.sh` in a throwaway Debian/Ubuntu container or WSL instance, and run it twice to confirm it is idempotent. Run `task lint` before opening a PR.

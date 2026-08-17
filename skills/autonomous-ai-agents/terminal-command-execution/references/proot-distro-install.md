# Proot-Distro Install Notes

## Verified Working Path for Hermes in Ubuntu proot-distro

- Hermes requires Python `>=3.11,<3.14`.
- If the container ships Python 3.14, install `python3.11` from deadsnakes PPA and use `python3.11 -m venv venv`.
- Clone source, then `pip install -e ".[all]"` inside that venv.
- Symlink `/usr/local/bin/hermes -> /root/.hermes/hermes-agent/venv/bin/hermes`.

## Installer Timeouts

- Official `install.sh` often times out on Node/native-module `npm install` in proot-distro.
- Fallback: manual git clone + Python venv + pip install; skip Node desktop tools unless needed.

## First Run Without Wizard

- In non-interactive shells, configure via `hermes config set ...`.
- Prefer writing secrets to `~/.hermes/.env`; settings to `config.yaml`.

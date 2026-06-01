# HAPI runners on Incus (LXC)

The two HAPI **runners** run as Incus system containers (the hubs + cloudflared
stay in Docker — see `../docker-compose.yml`). System containers give agents a
full OS: `apt install`, `sudo`, background services, even Docker-in-container —
the capabilities a coding agent expects, with stronger unprivileged isolation
than a Docker app container.

## Files

| File | Purpose |
|------|---------|
| `cloud-init.runner.yaml` | Provisions a stock `ubuntu/24.04/cloud` into a runner (Bun + Node 22 + agent CLIs + hapi source + systemd unit). Source of truth for the golden image. |
| `hapi-runner.service` | Canonical copy of the systemd unit (also embedded in cloud-init). |
| `profile-hapi-runner.yaml` | Reference of the `hapi-runner` Incus profile (built live by `bootstrap.sh`). |
| `bootstrap.sh` | Build the golden image once, then clone + provision both runners. |

## One-time host setup (Debian 13 / trixie)

```sh
sudo apt update && sudo apt install -y incus btrfs-progs
sudo adduser "$USER" incus-admin            # re-login afterwards
sudo incus admin init                       # storage=btrfs; bridge=incusbr0 (10.236.0.1/24)
```

Docker and Incus share the kernel firewall; Docker sets `FORWARD DROP` which
blocks `incusbr0`. Fix once:

```sh
echo '{ "ip-forward-no-drop": true }' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
# Fallback: sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT
```

## Deploy

```sh
cd ~/deploy            # holds .env with PERSONAL_TOKEN / WORK_TOKEN
# host must also have ~/.codex, ~/.local/share/opencode, ~/.claude, ~/.gemini
bash /path/to/deploy/incus/bootstrap.sh
```

## Two ways to run agents

**A. Hub-driven daemon (always-on):** the `hapi-runner` systemd service runs
`runner start-sync`, registers with the hub, and powers the web UI + Telegram.

**B. Interactive shell (code-on-incus style):** drop into a container and run an
agent directly in the terminal:

```sh
incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi codex'
#   or:  hapi opencode  |  hapi gemini  |  hapi   (Claude, the default)
```

Because `/etc/hapi.env` is sourced by login shells, this interactive session
also registers with the same hub — visible/controllable from web + Telegram.
For a fresh throwaway box per task, clone the golden image with `--ephemeral`:

```sh
incus launch hapi-runner-golden box-foo --ephemeral --profile hapi-runner
incus exec box-foo -t --cwd /workspace -- bash -lc 'hapi codex'
```

## Update HAPI

```sh
incus exec hapi-personal-runner -- bash -lc 'cd /opt/hapi && git pull && /root/.bun/bin/bun install'
incus exec hapi-personal-runner -- systemctl restart hapi-runner
```

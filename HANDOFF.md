# HAPI Self-Hosting Handoff — Single Hub, Two Hosts

This document records how the fork `github.com/jkryanchou/hapi` is deployed:
**one hub** at `https://hapi.jkryanchou.com` (merged from the former
personal+work split) with **two runners on two hosts**.

Last updated: 2026-06-04

---

## 1. Goal

One HAPI hub, namespace `default`, serving two runner machines for the two
development scenarios:

| Runner                | Host                              | Hub link (`HAPI_API_URL`)        |
|-----------------------|-----------------------------------|----------------------------------|
| `hapi-personal-runner`| `swas-sg-bgp` (Ubuntu 24.04)      | `http://10.195.198.1:3006` (bridge)|
| `hapi-work-runner`    | `ir-devnode-ryan` (Ubuntu 24.04)  | `https://hapi.jkryanchou.com`    |

> **2026-07-26 update:** the personal runner + hub moved off `netcup-us-admin`
> (retired) onto `swas-sg-bgp` per `deploy/MIGRATION-SG-CONSOLIDATION.md`. Every
> `netcup-us-admin` / `10.236.0.1` reference below this point is the pre-move
> state, left as-is except where corrected inline — the Debian-13/DOCKER-USER
> firewall specifics in §7 have NOT been re-verified against `swas-sg-bgp`
> (which reports as Ubuntu 24.04 live), so treat that subsection as historical
> until someone confirms it on the new host.

The **hub + cloudflared run in Docker on swas-sg-bgp** (hub image built by GitHub
Actions → GHCR); the **runners run as Incus (LXC) system containers** (§6a),
one per host. Both runners share the hub's base `CLI_API_TOKEN` (`HAPI_TOKEN`),
so everything appears under one web login and one Telegram bot.

---

## 2. Architecture

```
                 Cloudflare Edge (TLS)  hapi.jkryanchou.com
                          │
                ┌─────────┴─────────┐
                │    cloudflared     │  (--protocol http2, token-based)
                └─────────┬─────────┘
                          ▼
   swas-sg-bgp ────  hapi:3006  (Docker hub: REST+SSE+Telegram)
   │                 ▲      ▲ published on 10.195.198.1:3006 (incusbr0 GW)
   │   Socket.IO /cli│      │
   │  hapi-personal-runner ─┘   (Incus LXC, /workspace)
   │
   ir-devnode-ryan (AWS)
       hapi-work-runner ──► https://hapi.jkryanchou.com   (Incus LXC, /workspace;
                            Socket.IO /cli outbound through the tunnel)
```

- **Hub ↔ runner auth**: one shared base token `HAPI_TOKEN`; both runners use it
  verbatim → single namespace `default` (one login, one machine list, one bot).
- **swas-sg-bgp runner** reaches the hub privately over the Incus bridge gateway
  (`10.195.198.1:3006`); the DOCKER-USER firewall note in §7 is historical
  (written for the old netcup host) and has not been re-verified here.
- **devnode runner** reaches the hub over the public tunnel URL — outbound HTTPS
  only, no ingress needed on the devnode.
- `--protocol http2` is **required** for cloudflared (QUIC/UDP blocked on
  swas-sg-bgp; SSE needs it).

---

## 3. Images (GHCR)

Built by `.github/workflows/docker-publish.yml` on push to `main`, on `v*` tags,
and via `workflow_dispatch`; pushes `:latest` + `:sha`.

| Image                         | Dockerfile   | Contents                              |
|-------------------------------|--------------|----------------------------------------|
| `ghcr.io/jkryanchou/hapi-hub` | `Dockerfile` | Hub + embedded web PWA (slim runtime)  |

Auth uses the workflow's `GITHUB_TOKEN` with `packages: write` — no PAT needed.

> The runner is **not a Docker image**. It is an Incus container built from
> `deploy/incus/cloud-init.runner.yaml` + a local golden snapshot (no registry).
> `Dockerfile.runner` is retired to `deploy/legacy/`.

---

## 4. Key Files

| File                          | Purpose                                                       |
|-------------------------------|---------------------------------------------------------------|
| `Dockerfile`                  | hub image; embeds PWA via `generate:embedded-web-assets`      |
| `.github/workflows/docker-publish.yml` | CI build/push the **hub** image to GHCR              |
| `deploy/docker-compose.yml`   | 2 services (1 hub + cloudflared); runners are Incus           |
| `deploy/.env.example`         | documents required env vars (`HAPI_TOKEN`, …)                 |
| `deploy/incus/`               | runner cloud-init, systemd unit, profile, parameterized `bootstrap.sh` |
| `deploy/legacy/Dockerfile.runner` | retired Docker runner image (basis for the cloud-init)    |

---

## 5. Runner startup (Incus systemd unit)

The runner is an Incus system container running `hapi-runner.service` (see
`deploy/incus/hapi-runner.service`). systemd owns restart/signals. The unit:

1. `ConditionPathExists=/etc/hapi.env` — stays inactive until the hub link/token
   is provisioned (`bootstrap.sh` pushes it, then `systemctl enable --now`).
2. `ExecStartPre=rm -f /root/.hapi/runner.state.json*` — clears stale runner
   state (a reused PID can make `start-sync` think a runner is alive and exit).
3. `ExecStart=/root/.bun/bin/bun /opt/hapi/cli/src/index.ts runner start-sync
   --workspace-root /workspace` — foreground; `Restart=always`.

Non-secret config (codex `config.toml` trusting `/workspace`, opencode
`opencode.json` default model `github-copilot/claude-sonnet-4.6`) is baked into
the golden image by cloud-init. Update HAPI with
`git -C /opt/hapi pull && bun install && systemctl restart hapi-runner`.

---

## 6. Agent authentication strategy (Incus)

System containers have **writable** config dirs, so credentials are just files
pushed into the container once per runner (re-push only on rotation). No env-var
injection, no read-only mounts. Each host provisions its own runner's creds —
**work credentials on the devnode, personal credentials on netcup**.

| Agent       | Method (`incus file push` into the runner)  |
|-------------|---------------------------------------------|
| Claude Code | `~/.claude` → `/root/.claude`               |
| Gemini      | `~/.gemini` → `/root/.gemini`               |
| OpenCode    | `~/.local/share/opencode/auth.json`         |
| Codex       | `~/.codex/auth.json`                        |

### Codex specifics
- Codex Pro uses **ChatGPT OAuth tokens** (`auth_mode: chatgpt`), NOT
  `OPENAI_API_KEY`. The `auth.json` contains `id_token`, `access_token`,
  `refresh_token`, and `account_id` (nested under `tokens.…`).
- To refresh: `codex login` on the host (or any machine), then
  `incus file push ~/.codex/auth.json <runner>/root/.codex/auth.json`
  and `incus exec <runner> -- systemctl restart hapi-runner`.

### Historical note (Docker era)
Under Docker, opencode and codex failed with `EROFS` when their config dirs were
bind-mounted `:ro` (they write at runtime), which forced the
`OPENCODE_AUTH_JSON` / `CODEX_AUTH_JSON` env-var injection hack. The Incus move
**retires that hack** — a writable rootfs makes it unnecessary.

## 6a. Why the runner is Incus (LXC)
Docker is an *application*-container runtime (one process); agents want to behave
like they own a machine (`apt install`, `sudo`, daemons, Docker-in-container).
Incus *system* containers provide a full OS with systemd and a writable
filesystem, plus stronger unprivileged isolation via user namespaces. The benefit
is specific to the runner, so the hub + cloudflared stayed in Docker (hybrid).
Established pattern: `code-on-incus`, `lincubate`, `vibebin`.

---

## 7. Host A: netcup (`netcup-us-admin`, 152.53.209.61)

- Deploy dir: **`~/deploy/`** (NOT `~/hapi/deploy`).
- Env file: `~/deploy/.env` (git-ignored; holds all secrets).
- Compose file is **copied via `scp`**, not `git pull` — netcup has no repo
  clone, and `curl` from GitHub raw can serve a stale cached version.

### Required `.env` keys
```
TUNNEL_TOKEN=eyJ...
HAPI_TOKEN=...                # merged-hub base token (former PERSONAL_TOKEN value)
TELEGRAM_BOT_TOKEN=...        # the single bot (former personal bot)
INCUS_GW=10.236.0.1           # incusbr0 gateway; hub publishes here
```
> Agent creds are not in `.env` — `deploy/incus/bootstrap.sh` pushes
> `~/.codex/auth.json`, `~/.local/share/opencode/auth.json`, `~/.claude`,
> `~/.gemini` directly into the runner from the host home dir.

### One-time Incus host setup (Debian 13 / trixie)
```sh
sudo apt install -y incus btrfs-progs
sudo adduser admin incus-admin            # re-login (until then use `sudo incus`)
sudo incus admin init                     # btrfs pool; bridge incusbr0 = 10.236.0.1/24
```

#### Docker ↔ Incus firewall (the part that actually bit us)
`ip-forward-no-drop` in `daemon.json` was **NOT sufficient** on this host: Docker
(nft backend) still installs a `filter forward … policy drop` hook that overrides
Incus's own `fwd.incusbr0` chain, so containers got "Network is unreachable"
during cloud-init. The working fix is explicit `DOCKER-USER` ACCEPT rules for
`incusbr0`, **persisted** so they survive a Docker restart:

```sh
sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT
sudo iptables -I DOCKER-USER -o incusbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo apt install -y iptables-persistent && sudo netfilter-persistent save

# Re-apply on every Docker restart (Docker flushes DOCKER-USER on restart):
#   /usr/local/sbin/incus-docker-forward.sh   — idempotent `iptables -C || -I` of the two rules
#   /etc/systemd/system/docker.service.d/incus-forward.conf:
#     [Service]
#     ExecStartPost=/usr/local/sbin/incus-docker-forward.sh
```
> These two host files live on netcup only, not in the repo.

### Deploy / redeploy (hub)
```sh
scp deploy/docker-compose.yml netcup-us-admin:~/deploy/docker-compose.yml
ssh netcup-us-admin 'cd ~/deploy && docker compose pull && docker compose up -d --remove-orphans'
```
> **Always run compose from `~/deploy`** — the project name (`deploy`) prefixes
> the data volume (§11). A different directory or `-p` silently creates a fresh
> empty volume.

### Provision / re-provision the runner
```sh
scp -r deploy/incus netcup-us-admin:~/deploy/incus
ssh netcup-us-admin 'RUNNER_NAME=hapi-personal-runner WORKSPACE_VOL=personal-workspace \
  HAPI_API_URL=http://10.236.0.1:3006 bash ~/deploy/incus/bootstrap.sh'
```

---

## 8. Host B: ir-devnode-ryan (AWS Ubuntu 24.04)

Work devbox; user `ubuntu` (passwordless sudo). Runs **only** the
`hapi-work-runner` Incus container — no Docker, no hub, no ingress. The runner
connects outbound to `https://hapi.jkryanchou.com` through the Cloudflare edge.

### One-time host setup
```sh
sudo apt update && sudo apt install -y incus btrfs-progs
sudo adduser ubuntu incus-admin           # re-login afterwards
sudo incus admin init                     # storage=btrfs (or dir); bridge=incusbr0 w/ NAT
```
No Docker on this host → the §7 firewall workaround is **not needed**.

### Provision the runner
```sh
scp -r deploy/incus ir-devnode-ryan:~/deploy-incus
ssh ir-devnode-ryan 'RUNNER_NAME=hapi-work-runner WORKSPACE_VOL=work-workspace \
  HAPI_API_URL=https://hapi.jkryanchou.com HAPI_TOKEN=<token> \
  ENV_FILE=/dev/null bash ~/deploy-incus/bootstrap.sh'
```

### Agent credentials (work)
The fresh devnode has no agent creds; bootstrap skips missing files. Authenticate
with **work** accounts either inside the container
(`incus exec hapi-work-runner -t -- bash -lc 'claude /login'`, `codex login`, …)
or on the devnode host and re-run bootstrap (cred push is idempotent), then
`incus exec hapi-work-runner -- systemctl restart hapi-runner`.

---

## 9. Using the runners — the two scenarios

A runner container serves agents in **two independent ways**. Both register with
the same hub (visible in the web UI + Telegram), because the systemd unit and
login shells read the same `/etc/hapi.env`.

> **`hapi` is a shim, not an npm bin.** The runner runs from the source clone;
> `/usr/local/bin/hapi` (`exec /root/.bun/bin/bun /opt/hapi/cli/src/index.ts "$@"`)
> is baked into `cloud-init.runner.yaml`.

### Scenario A — Hub-driven daemon (web UI + Telegram)
The always-on path: `hapi-runner` runs `runner start-sync`, registers, and
spawns sessions on demand.

1. Open `https://hapi.jkryanchou.com`.
2. **New session** → pick the machine (`hapi-personal-runner` or
   `hapi-work-runner`) → pick an agent → browse to a workspace dir → create.

Operate from the host:
```sh
incus exec hapi-work-runner -- systemctl status hapi-runner
incus exec hapi-work-runner -- journalctl -u hapi-runner -f
incus exec hapi-work-runner -- systemctl restart hapi-runner
```

### Scenario B — Interactive agent shell (code-on-incus style)
```sh
incus exec hapi-work-runner -t --cwd /workspace -- bash -lc 'hapi codex'
#   or:  hapi opencode  |  hapi gemini  |  hapi   (Claude, the default)

# Pure local TUI, do NOT register with the hub:
incus exec hapi-work-runner -t --cwd /workspace -- bash -lc 'hapi codex --hapi-starting-mode local'

# Throwaway, isolated box per task (auto-deleted on stop):
incus launch hapi-runner-golden box-spike --ephemeral --profile hapi-runner
incus exec box-spike -t --cwd /workspace -- bash -lc 'hapi codex'
incus stop box-spike     # gone
```

---

## 10. Cloudflare Tunnel

- Tunnel `hapi`, UUID `873b1a26-fce2-4f09-9f36-4a0a72272cb2`,
  account `d4aed0ddf005e866f5c80d21df7e8b09`, zone `jkryanchou.com`.
- Remotely-managed (token-based); single ingress route:
  - `hapi.jkryanchou.com` → `http://hapi:3006`
- The old `hapi-personal.jkryanchou.com` / `hapi-work.jkryanchou.com` routes +
  DNS records were removed at the 2026-06 merge cutover.

---

## 11. Data continuity (the hub merge)

The merged hub **kept the former personal hub's state**: the compose volume KEY
is still `hapi-personal-data`, so the existing docker volume
`deploy_hapi-personal-data` (SQLite DB, `jwt-secret.json`, `owner-id.json`,
`settings.json`, Telegram bindings) is reused with **no data migration**.

- `HAPI_TOKEN` keeps the former `PERSONAL_TOKEN` value → the netcup runner and
  all existing web/Telegram pairings kept working unchanged.
- `HAPI_PUBLIC_URL` env overrides the stale URL persisted in `settings.json`
  (config priority: env > settings.json > default) — do not drop the env vars
  from compose.
- ⚠️ **Compose project name = volume prefix.** Run compose from `~/deploy`
  (project `deploy`); anything else resolves the volume key to a fresh empty
  volume and the hub silently loses its state.
- The former work hub's history was intentionally discarded at the merge
  (its DB volume `deploy_hapi-work-data` deleted).

## 12. Telegram

One bot for the single hub (the former personal bot), wired via
`TELEGRAM_BOT_TOKEN`. Bindings carried over with the data volume. The former
work bot is retired. If the Mini App / menu button still points at the old
domain, update it in @BotFather to `https://hapi.jkryanchou.com`.

---

## 13. Problems solved (carried forward where still relevant)

1. **npm missing in `oven/bun`** → install Node.js 22 via NodeSource before
   `npm install -g` of agent CLIs (cloud-init does this).
2. **Runner crash-loop** (stale `runner.state.json` PID match) → `rm -f` state
   in `ExecStartPre`.
3. **`unzip` missing** → the Bun installer needs it; in the cloud-init
   `packages` list.
4. **`cloud-init status --wait` returned too early** → poll with
   `until cloud-init status | grep -qE 'done|error'` (bootstrap.sh does this).
5. **`incus launch --device workspace,…` rejected** → `--device` at launch can
   only override existing profile devices; launch first, then
   `incus config device add … workspace disk …` (bootstrap.sh does this).
6. **`incus file push` "Permission denied"** → host cred dirs root-owned from
   the Docker bind-mount era; `chown -R` them to the invoking user first.
7. **Docker ↔ Incus firewall on netcup** → explicit persisted `DOCKER-USER`
   ACCEPT rules (§7); `ip-forward-no-drop` alone is not enough.
8. **Stale compose after `docker compose up`** → use `scp` + `--remove-orphans`
   (and `--force-recreate` when mounts change).
9. **EROFS with `:ro` cred bind-mounts (Docker era)** → historical; retired by
   the Incus move (§6).
10. **OpenCode model 400** → default to `github-copilot/claude-sonnet-4.6`
    (baked into cloud-init).
11. **Repos not visible in the session browser** → the runner's `/workspace`
    must contain clones; generate an ed25519 **deploy key inside the runner**
    (never move host private keys in) and add it via `gh api repos/…/keys`.

---

## 14. Status / crib sheet

### Update HAPI inside a runner (after any push to main)
```sh
# swas-sg-bgp (personal runner; main is force-pushed on rebase, so reset --hard,
# NOT git pull --ff-only — the latter will fail after any upstream rebase)
ssh swas-sg-bgp
sudo incus exec hapi-personal-runner -- bash -lc 'cd /opt/hapi && git fetch origin && git reset --hard origin/main && /root/.bun/bin/bun install'
sudo incus exec hapi-personal-runner -- systemctl restart hapi-runner

# devnode
ssh ir-devnode-ryan
incus exec hapi-work-runner -- bash -lc 'cd /opt/hapi && git fetch origin && git reset --hard origin/main && /root/.bun/bin/bun install'
incus exec hapi-work-runner -- systemctl restart hapi-runner
```

### Update the hub (after CI publishes; check docker-publish is green first)
```sh
ssh swas-sg-bgp 'cd ~/deploy && docker compose pull hapi && docker compose up -d hapi'
```

### Health
```sh
curl -sI https://hapi.jkryanchou.com                                  # 200 via tunnel
ssh swas-sg-bgp 'curl -sI http://10.195.198.1:3006'                   # 200 on the bridge
ssh swas-sg-bgp 'sudo incus exec hapi-personal-runner -- journalctl -u hapi-runner -n 20 --no-pager'
ssh ir-devnode-ryan 'incus exec hapi-work-runner -- journalctl -u hapi-runner -n 20 --no-pager'
```

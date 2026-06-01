# HAPI Self-Hosting Handoff

This document records the work done to fork, dockerize, and deploy **two HAPI
stacks** (personal + work) on the `netcup-us-admin` server behind a shared
Cloudflare Tunnel.

Last updated: 2026-06-01

---

## 1. Goal

Run two independent HAPI stacks from the fork `github.com/jkryanchou/hapi`:

| Stack    | Hub URL                              | Agents available                       |
|----------|--------------------------------------|----------------------------------------|
| personal | `https://hapi-personal.jkryanchou.com` | Claude Code, Codex, OpenCode, Gemini   |
| work     | `https://hapi-work.jkryanchou.com`     | Claude Code, Codex, OpenCode, Gemini   |

Each stack = **one hub + one dedicated runner**. A single `cloudflared`
container fronts both. Images are built by GitHub Actions and pushed to GHCR.

---

## 2. Architecture

```
                    Cloudflare Edge (TLS)
                            │
                  ┌─────────┴─────────┐
                  │   cloudflared      │  (--protocol http2, token-based)
                  │   (1 shared)       │
                  └─────────┬─────────┘
            ┌───────────────┴───────────────┐
            ▼                                ▼
   hapi-personal:3006              hapi-work:3006        (hub: REST+SSE+Telegram)
            ▲                                ▲
            │ Socket.IO /cli                 │ Socket.IO /cli
   hapi-personal-runner            hapi-work-runner       (spawns agent sessions)
   workspace: /workspace           workspace: /workspace
```

- **Hub ↔ Runner pairing**: shared `CLI_API_TOKEN` per stack
  (`PERSONAL_TOKEN`, `WORK_TOKEN`).
- **Runner ↔ Hub link**: `HAPI_API_URL` points the runner at its hub over the
  internal `hapi-net` Docker network.
- **No host ports published** — all traffic flows through cloudflared.
- `--protocol http2` is **required** (QUIC/UDP is blocked on netcup; SSE needs it).

---

## 3. Images (GHCR)

Built by `.github/workflows/docker-publish.yml` on push to `main`, on `v*` tags,
and via `workflow_dispatch`. Matrix builds both images; pushes `:latest` + `:sha`.

| Image                              | Dockerfile         | Contents                                          |
|------------------------------------|--------------------|---------------------------------------------------|
| `ghcr.io/jkryanchou/hapi-hub`      | `Dockerfile`       | Hub + embedded web PWA (slim runtime)             |
| `ghcr.io/jkryanchou/hapi-runner`   | `Dockerfile.runner`| Bun + Node 22 + agent CLIs (claude/codex/gemini/opencode) |

Auth uses the workflow's `GITHUB_TOKEN` with `packages: write` — no PAT needed.

---

## 4. Key Files

| File                          | Purpose                                                       |
|-------------------------------|---------------------------------------------------------------|
| `Dockerfile`                  | hub image; embeds PWA via `generate:embedded-web-assets`      |
| `Dockerfile.runner`           | runner image; installs Node 22 + agent CLIs; CMD seeds auth   |
| `.dockerignore`               | excludes git, node_modules, dist, generated assets            |
| `.github/workflows/docker-publish.yml` | CI build/push both images to GHCR                    |
| `deploy/docker-compose.yml`   | 5 services (2 hubs, 2 runners, cloudflared)                   |
| `deploy/.env.example`         | documents required env vars                                   |

---

## 5. Runner CMD startup sequence

The runner image must run **foreground** (`runner start-sync`, not `start`
which daemonizes and exits → kills the container). On each startup the CMD:

1. **Clears stale runner state** — `runner.state.json` persists in the named
   volume across restarts. Docker reuses low PIDs, which can match the stale
   PID, making `start-sync` think a runner is already alive and exit → restart
   loop. Removing the file on boot prevents this.
2. **Seeds opencode auth** — writes `OPENCODE_AUTH_JSON` to
   `~/.local/share/opencode/auth.json` and a config at
   `~/.config/opencode/opencode.json` (default model
   `github-copilot/claude-sonnet-4.6`).
3. **Seeds codex auth** — writes `CODEX_AUTH_JSON` to `~/.codex/auth.json` and
   a minimal `~/.codex/config.toml` trusting `/workspace`.
4. `exec bun ...` so bun becomes PID 1 and handles SIGTERM.

---

## 6. Agent authentication strategy

| Agent       | Method                          | Why                                                  |
|-------------|---------------------------------|------------------------------------------------------|
| Claude Code | RO bind-mount `~/.claude`       | Static credentials, no writes needed                 |
| Gemini      | RO bind-mount `~/.gemini`       | Static credentials                                   |
| OpenCode    | `OPENCODE_AUTH_JSON` env var    | Needs **write** access (creates `repos/`) → can't be `:ro` |
| Codex       | `CODEX_AUTH_JSON` env var       | Needs **write** access (sessions, DBs) → can't be `:ro` |

**Lesson learned:** opencode and codex both fail with `EROFS: read-only file
system` if their config dirs are bind-mounted `:ro`. They write to their own
dirs at runtime. The fix for both: inject `auth.json` content via an env var and
write it to a writable in-container path on startup. The `:ro` bind-mounts for
these two were removed from compose.

### Codex specifics
- Codex Pro uses **ChatGPT OAuth tokens** (`auth_mode: chatgpt`), NOT
  `OPENAI_API_KEY`. The `auth.json` contains `id_token`, `access_token`,
  `refresh_token`, and `account_id`.
- To refresh on netcup: `jq -c . ~/.codex/auth.json` locally, then update the
  `CODEX_AUTH_JSON=...` line in `~/deploy/.env` and force-recreate the runners.

---

## 7. Deployment on netcup (`netcup-us-admin`, 152.53.209.61)

- Deploy dir: **`~/deploy/`** (NOT `~/hapi/deploy`).
- Env file: `~/deploy/.env` (git-ignored; holds all secrets).
- Compose file is **copied via `scp`**, not `git pull` — netcup has no repo
  clone, and `curl` from GitHub raw can serve a stale cached version.

### Required `.env` keys
```
TUNNEL_TOKEN=eyJ...
PERSONAL_TOKEN=...
WORK_TOKEN=...
HOST_HOME=/home/admin
PERSONAL_TELEGRAM_BOT_TOKEN=...     # @HAPIPeronsalBot
WORK_TELEGRAM_BOT_TOKEN=...         # @HAPIWorkBot
OPENCODE_AUTH_JSON={...}
CODEX_AUTH_JSON={...}
```

### Redeploy after image change
```sh
ssh netcup-us-admin
cd ~/deploy
docker compose pull hapi-personal-runner hapi-work-runner
docker compose up -d --force-recreate hapi-personal-runner hapi-work-runner
```
> Use `--force-recreate` when changing **volume mounts** in compose — Docker
> otherwise reuses the existing container and ignores the new config.

### Update only the compose file
```sh
scp deploy/docker-compose.yml netcup-us-admin:~/deploy/docker-compose.yml
```

---

## 8. Cloudflare Tunnel

- Tunnel `hapi`, UUID `873b1a26-fce2-4f09-9f36-4a0a72272cb2`,
  account `d4aed0ddf005e866f5c80d21df7e8b09`, zone `jkryanchou.com`.
- Remotely-managed (token-based); ingress routes configured in the dashboard:
  - `hapi-personal.jkryanchou.com` → `http://hapi-personal:3006`
  - `hapi-work.jkryanchou.com` → `http://hapi-work:3006`
- Two proxied CNAMEs point at `873b1a26-….cfargotunnel.com`.
- Old `hapi.jkryanchou.com` route + DNS record removed at cutover.

---

## 9. Telegram bots

One bot per hub (a single bot cannot serve two hubs):
- Personal: `@HAPIPeronsalBot` → `PERSONAL_TELEGRAM_BOT_TOKEN`
- Work: `@HAPIWorkBot` → `WORK_TELEGRAM_BOT_TOKEN`

Wired via `TELEGRAM_BOT_TOKEN` env on each hub service.

---

## 10. Personal hub state migration

Migrated from the old Lightsail SG box (`lightsail-sg-ubuntu`, 47.130.105.246):
copied `~/.hapi/{settings.json, jwt-secret.json, owner-id.json, hapi.db*}` into
the `hapi-personal-data` volume so existing sessions, pairings, and the owner
identity carried over. `HAPI_PUBLIC_URL` env overrides the old public URL. The
SG tmux sessions were stopped (old setup retired). The personal workspace volume
was seeded with a clone of `git@github.com:jkryanchou/code-handoff.git`.

---

## 11. Problems solved (chronological)

1. **npm missing in `oven/bun`** → install Node.js 22 via NodeSource before
   `npm install -g` of agent CLIs.
2. **Runner crash-loop** (stale `runner.state.json` PID match) → `rm -f` state
   on startup; `exec bun` for correct PID 1 / signal handling.
3. **No machine in `/sessions/new`** → caused by #2; resolved once runner stayed up.
4. **OpenCode `ACP process exited (code=1)`** → `:ro` mount of opencode dirs
   caused `EROFS`. Fix: inject auth via env var, write to writable paths.
5. **OpenCode no response (HTTP 400)** → model `claude-opus-4.6` not available
   for the `opencode` integrator. Fix: default to `claude-sonnet-4.6`.
6. **One Telegram bot for two hubs** → created two bots, one per hub.
7. **Codex `Read-only file system` for `~/.codex/auth.json`** (same class as #4)
   → removed `:ro` codex bind-mount; inject `CODEX_AUTH_JSON` env var.
8. **Stale compose after `docker compose up`** → Docker reused old container with
   old mounts; fixed with `--force-recreate`. Also `curl` from GitHub raw served
   a cached file → switched to `scp` of the local compose file.

---

## 12. Current status

- ✅ CI builds and pushes both images to GHCR on every push to `main`.
- ✅ Both stacks deployed on netcup behind one Cloudflare Tunnel.
- ✅ Personal hub state migrated; SG box retired.
- ✅ Two Telegram bots configured.
- ✅ OpenCode working (GitHub Copilot, `claude-sonnet-4.6`).
- ✅ Codex working (ChatGPT OAuth via `CODEX_AUTH_JSON`); auth.json verified
  inside the personal runner (`auth_mode: chatgpt`, access token present).
- Both runners stable (`Up`, registered with their hubs, workspace `/workspace`).

### Next steps / notes
- Create a Codex session at `https://hapi-personal.jkryanchou.com/sessions/new`
  (agent: Codex, workspace `/workspace`).
- Claude Code / Gemini still need their host credential dirs populated on netcup
  (`/home/admin/.claude`, `/home/admin/.gemini`) if those agents are wanted.
- ChatGPT OAuth tokens expire — refresh `CODEX_AUTH_JSON` in `~/deploy/.env`
  from a fresh local `~/.codex/auth.json` when codex stops authenticating.

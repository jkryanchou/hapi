# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is HAPI?

Local-first platform for running AI coding agents (Claude Code, Codex, Gemini) with remote control via web/phone. Three-tier architecture: CLI wraps agents and connects to hub via Socket.IO; hub serves REST API + SSE + Telegram bot with SQLite persistence; web is a React PWA consuming SSE for real-time updates.

## Commands

```bash
bun install                  # Install all dependencies
bun run dev                  # Run hub + web concurrently (dev mode)
bun run dev:hub              # Hub only with watch
bun run dev:web              # Web only with Vite dev server
bun typecheck                # Type check all packages
bun run test                 # Run all tests (cli + hub)
bun run test:cli             # CLI tests only
bun run test:hub             # Hub tests only
bun run test:web             # Web tests only
bun run build                # Build all packages
bun run build:single-exe     # All-in-one binary with embedded web assets
```

Tests use Vitest. Test files live next to source as `*.test.ts`. Run a single test file:
```bash
cd cli && bunx vitest run src/path/to/file.test.ts
cd hub && bunx vitest run src/path/to/file.test.ts
```

## Repo Layout

```
cli/     - CLI binary, agent wrappers, runner daemon
hub/     - Fastify HTTP API + Socket.IO + SSE + Telegram bot
web/     - React PWA (Vite, TanStack Router/Query, xterm.js)
shared/  - Common types, Zod schemas, Socket.IO event definitions
docs/    - VitePress documentation site
website/ - Marketing site
```

Bun workspaces monorepo. `shared` is consumed by cli, hub, and web.

## Architecture

**Data flow:** CLI spawns agent -> events flow via Socket.IO to hub -> hub persists to SQLite + broadcasts via SSE -> web subscribes to SSE for live updates. User actions go: web -> hub REST API -> RPC to CLI -> agent.

**Key patterns:**
- **RPC system**: CLI registers handlers (`rpc-register`), hub routes via `rpcGateway.ts`
- **Versioned updates**: Metadata/state updates carry a version number; hub rejects stale writes (optimistic concurrency)
- **Session modes**: `local` (terminal-controlled) vs `remote` (web-controlled), switchable mid-session
- **Permission modes**: `default`, `acceptEdits`, `bypassPermissions`, `plan`
- **Namespaces**: Multi-user isolation via `CLI_API_TOKEN:<namespace>` suffix

## Code Conventions

- TypeScript strict mode; no untyped code
- 4-space indentation
- Path alias `@/*` maps to `./src/*` per package
- Zod for runtime validation (shared schemas in `shared/src/schemas.ts`)
- No backward compatibility concerns: breaking old formats freely is acceptable
- Prioritize pragmatism; avoid overengineering
- Write necessary tests only

## Key Files for Common Tasks

| Task | Key files |
|------|-----------|
| Add CLI command | `cli/src/commands/`, `cli/src/index.ts` |
| Add API endpoint | `hub/src/web/routes/`, register in `hub/src/web/index.ts` |
| Add Socket.IO event | `hub/src/socket/handlers/cli/`, `shared/src/socket.ts` |
| Add web route | `web/src/routes/`, `web/src/router.tsx` |
| Modify session logic | `hub/src/sync/sessionCache.ts`, `hub/src/sync/syncEngine.ts` |
| Modify message handling | `hub/src/sync/messageService.ts` |
| Add shared type | `shared/src/types.ts`, `shared/src/schemas.ts` |

## Tech Stack

- **Runtime**: Bun
- **Backend**: Fastify, Socket.IO, better-sqlite3
- **Frontend**: React 19, Vite, TanStack Router/Query, Tailwind CSS, Radix UI, assistant-ui
- **Real-time**: Socket.IO (CLI<->Hub) + SSE (Hub<->Web)
- **Validation**: Zod
- **Telegram**: grammy
- **Terminal**: xterm.js
- **Voice**: ElevenLabs
- **Relay**: WireGuard + TLS

# syntax=docker/dockerfile:1

# ── Stage 1: install all workspace dependencies ──────────────────────────────
FROM oven/bun:1.3.14 AS deps
WORKDIR /app

# Copy workspace manifests first so bun install is cached
COPY package.json bun.lock ./
COPY cli/package.json     cli/package.json
COPY hub/package.json     hub/package.json
COPY web/package.json     web/package.json
COPY shared/package.json  shared/package.json
COPY website/package.json website/package.json
COPY docs/package.json    docs/package.json

RUN bun install --frozen-lockfile

# ── Stage 2: build web PWA + embed assets into the hub ───────────────────────
FROM oven/bun:1.3.14 AS build
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# 1. Build the React PWA
RUN bun run --cwd web build

# 2. Embed web/dist into hub/src/web/embeddedAssets.generated.ts
RUN cd hub && bun run generate:embedded-web-assets

# ── Stage 3: lean runtime image ───────────────────────────────────────────────
FROM oven/bun:1.3.14-slim AS runtime
WORKDIR /app

COPY --from=build /app ./

ENV HAPI_LISTEN_HOST=0.0.0.0 \
    HAPI_LISTEN_PORT=3006

EXPOSE 3006

# Hub persists its SQLite DB, JWT secret, settings, and owner ID here.
# Always mount a named volume at this path so state survives container restarts.
VOLUME ["/root/.hapi"]

CMD ["bun", "run", "--cwd", "hub", "start"]

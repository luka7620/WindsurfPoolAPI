# Zero-dependency Node 20 runtime. The project has no `npm install` step —
# everything lives in `node:*` builtins — so this image is effectively
# Node + source, nothing else.
ARG NODE_IMAGE=node:20-alpine
FROM ${NODE_IMAGE}

# Non-root user for the app. Keep the UID/GID stable so host bind mounts can
# be chowned once by install scripts and remain writable across image updates.
ARG APP_UID=10001
ARG APP_GID=10001
RUN addgroup -S -g "${APP_GID}" app && adduser -S -D -H -u "${APP_UID}" -G app app

WORKDIR /app

# Copy source. `.dockerignore` keeps runtime artefacts (accounts.json, .env,
# stats.json, data/, logs/) out even if they exist in the build context.
COPY --chown=app:app package.json ./
COPY --chown=app:app src ./src
COPY --chown=app:app docs ./docs

# The Language Server binary is NOT bundled (closed-source Windsurf release);
# mount it at runtime. See docker-compose.yml for the bind-mount example.
ENV PORT=3003
ENV LS_PORT=42100
ENV LOG_LEVEL=info

# Writable locations for runtime state
RUN mkdir -p /app/logs /tmp/windsurf-workspace \
    && chown -R app:app /app /tmp/windsurf-workspace

USER app

EXPOSE 3003

# Simple healthcheck — /health is served by the HTTP server even when the
# account pool is empty.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3003/health || exit 1

CMD ["node", "src/index.js"]

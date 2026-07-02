# syntax=docker/dockerfile:1
# Postiz AI rewrite-proxy. Sits as a sidecar next to the postiz monolith.
# Intercepts every openai-node SDK call from Postiz (which sets
# OPENAI_BASE_URL=http://localhost:8080/v1), rewrites the hardcoded model
# name 'gpt-4.1' to 'minimax/minimax-m3', and forwards to OpenRouter.
#
# Build:  docker build -t ghcr.io/rubiconetic/postiz-ai-proxy:0.1.0 .
# Push:   docker push ghcr.io/rubiconetic/postiz-ai-proxy:0.1.0
#
# Image size: ~80MB (vs ~5MB for a pure alpine). node:20-alpine already
# has npm, but the runtime image doesn't need it — we copy a pre-built
# node_modules from the builder stage so the final image never runs npm
# at pod start. Init containers / emptyDirs / ConfigMap source mounts
# all become unnecessary once this image is in use.

# ---- Build stage --------------------------------------------------------
FROM node:20-alpine AS builder
WORKDIR /build

# Install only what we need. express is the sole runtime dependency.
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

# Copy the source last so dependency layer caches across code changes.
COPY server.js ./

# ---- Runtime stage ------------------------------------------------------
FROM node:20-alpine AS runtime
WORKDIR /app

# Run as the unprivileged 'node' user that the base image ships.
# node:20-alpine already creates uid:gid 1000:1000 with the right home.
USER node

# Copy only what the runtime needs. No npm, no dev deps, no shell needed.
COPY --from=builder --chown=node:node /build/node_modules ./node_modules
COPY --from=builder --chown=node:node /build/server.js ./server.js
COPY --from=builder --chown=node:node /build/package.json ./package.json

# Drop all capabilities, set a read-only root filesystem-friendly defaults.
# (Postiz's pod spec already sets securityContext; this is defense-in-depth.)
EXPOSE 8080

# Healthcheck for `docker run` parity. K8s uses its own probe against /.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e 'fetch("http://127.0.0.1:8080/").then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))'

CMD ["node", "server.js"]
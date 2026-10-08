# Demo API image. It is built and scanned in CI but not deployed (ADR-018).
# Base images are pinned by digest; Dependabot updates them. The runtime image is distroless: no shell,
# no package manager and no npm, so the image SBOM holds little beyond Node.js and the app (ADR-023).

# Images stay on FROM lines (not in ARGs) so Dependabot can update their digests.
FROM node:24.21.0-trixie-slim@sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66 AS node

# Production dependencies only, exactly as locked.
FROM node AS dependencies
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
RUN npm ci --omit=dev

# Compile TypeScript with the full toolchain.
FROM node AS build
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:9eeb7f5887d0e239e78264b06f7f11d2e14be534050481803a9e4728fcdd278e
ARG GIT_COMMIT=unknown
LABEL org.opencontainers.image.title="sssc-demo-api" \
      org.opencontainers.image.source="https://github.com/vkorzavatykh/secure-software-supply-chain-aws" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.licenses="MIT"
ENV NODE_ENV=production \
    PORT=3000 \
    GIT_COMMIT=${GIT_COMMIT}
WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
# The distroless :nonroot image already runs as UID 65532; stating it keeps that explicit.
USER 65532:65532
EXPOSE 3000
# The image's entrypoint is the Node.js binary.
CMD ["dist/server.js"]

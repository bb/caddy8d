# Custom Caddy with Mercure and Brotli, in three variants:
#
#   docker build --build-arg VARIANT=base .      # Caddy + Mercure + cbrotli
#   docker build --build-arg VARIANT=souin .     # base + Souin (HTTP cache)
#   docker build --build-arg VARIANT=anycable .  # base + AnyCable
#
# Each also exists with the layer4 app (TCP/TLS routing, mholt/caddy-l4):
# VARIANT=l4, souin-l4, anycable-l4.
#
# Plugin versions come from variants/<VARIANT>/go.mod (bumped by Dependabot),
# not from xcaddy: xcaddy pins Caddy to the builder image's version, which
# breaks as soon as a plugin requires a newer Caddy than the image ships.
#
# Base images are pinned by digest and bumped by Dependabot.

FROM golang:1.27.3-alpine3.24@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS builder

# cbrotli links against the C brotli library, so the build needs cgo
RUN apk add --no-cache gcc musl-dev brotli-dev git libcap-setcap

ARG VARIANT=base
# Same tags as the official Mercure builds: they keep 0.x clients and tokens
# working under `protocol_version_compatibility 8` (see README.md, Mercure 1.0)
ARG GO_TAGS="deprecated_topic deprecated_claim deprecated_transport"
WORKDIR /src
COPY variants/${VARIANT}/go.mod variants/${VARIANT}/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY variants/${VARIANT}/ ./
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 go build -tags "$GO_TAGS" -trimpath -ldflags '-s -w' -o /usr/bin/caddy . \
    # Lets a non-root caddy bind to ports below 1024, like the official image.
    # Set here rather than in the final stage, where changing the file would
    # store the whole binary in a second layer; COPY keeps the capability.
    && setcap cap_net_bind_service=+ep /usr/bin/caddy


# The official image provides the layout (/etc/caddy, /data, /config, default
# Caddyfile, XDG env, CMD); only the binary is replaced. Its tag can lag behind
# the Caddy version in go.mod: `caddy version` is what counts.
FROM caddy:2.11.7-alpine@sha256:e70b164da81ef698b3ad19af799ea6086ce6d9e48ed4079eb9fe26f6fbf14ee5

ARG VARIANT=base
RUN apk add --no-cache brotli-libs
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
RUN getcap /usr/bin/caddy | grep -q cap_net_bind_service \
    && caddy version \
    && caddy list-modules --skip-standard | grep -qx http.handlers.mercure \
    && caddy list-modules --skip-standard | grep -qx http.encoders.br \
    && case "$VARIANT" in l4|*-l4) caddy list-modules --skip-standard | grep -qx caddy.listeners.layer4 ;; esac

LABEL org.opencontainers.image.variant=${VARIANT}

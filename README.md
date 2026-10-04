# caddy8d

[Caddy](https://caddyserver.com) with [Mercure](https://mercure.rocks) and
[Brotli](https://github.com/dunglas/caddy-cbrotli) compression, plus variants
with the [Souin](https://github.com/darkweak/souin) HTTP cache or
[AnyCable](https://github.com/evilmartians/caddy_anycable). A drop-in
replacement for the official `caddy` image: same paths, same default command.

New Caddy, Mercure and plugin releases are picked up automatically. Each one
is built and smoke-tested before it is published.

## Images and tags

Published to Docker Hub (`bock/caddy8d`) and GHCR (`ghcr.io/bb/caddy8d`) for
`linux/amd64` and `linux/arm64`.

| Variant    | Contents                          | Floating tags                     | Pinned tags                              |
|------------|-----------------------------------|-----------------------------------|------------------------------------------|
| `base`     | Caddy, Mercure, cbrotli           | `latest`, `2`, `2.11`, `2.11.7`   | `2.11.7-20261004-0312`                   |
| `souin`    | base + Souin HTTP cache           | `souin`, `2-souin`, `2.11-souin`, `2.11.7-souin` | `2.11.7-souin-20261004-0312` |
| `anycable` | base + AnyCable (WebSocket)       | `anycable`, `2-anycable`, `2.11-anycable`, `2.11.7-anycable` | `2.11.7-anycable-20261004-0312` |

The version in the tag is the Caddy version compiled in. The floating tags
follow rebuilds: new plugin releases and weekly Alpine updates. A dated tag
always points to one specific build, so use it to pin a server or roll back.
The plugin versions of each build are listed in the summary of the workflow
run that published it, and `caddy list-modules --versions` prints them too.

## Usage

```yaml
services:
  caddy:
    image: bock/caddy8d:2
    environment:
      MERCURE_PUBLISHER_JWT_KEY: ${MERCURE_PUBLISHER_JWT_KEY:?}
      MERCURE_SUBSCRIBER_JWT_KEY: ${MERCURE_SUBSCRIBER_JWT_KEY:?}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./mercure:/mercure
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data:
  caddy_config:
```

See [examples/](examples/) for a complete Caddyfile with two Mercure hubs.

## Upgrading from Mercure 0.x

Mercure 1.0 changed the protocol: tokens are OAuth access tokens, subscribers
use `match=` instead of `topic=`, and JWT keys move into `issuer` blocks
([upgrade guide](https://github.com/dunglas/mercure/blob/main/docs/UPGRADE.md)).
A 0.x Caddyfile **fails to start** without changes. These images are built
with the same compatibility tags as the official Mercure builds, so existing
apps keep working once each `mercure` block gets two changes:

```caddyfile
mercure {
	name app                          # required when there is more than one hub
	protocol_version_compatibility 8  # accept 0.x clients and tokens
	publisher_jwt {env.MERCURE_PUBLISHER_JWT_KEY}
	subscriber_jwt {env.MERCURE_SUBSCRIBER_JWT_KEY}
	transport bolt {
		path /mercure/app-mercure.db
	}
}
```

Compatibility mode relaxes token validation and accepts the token in the URL
query, so also redact `authorization` from access logs (see
[examples/Caddyfile](examples/Caddyfile)). Plan to migrate the apps' tokens
and subscribe URLs and then remove `protocol_version_compatibility`.

## Known limitations

- **AnyCable SSE does not work inside Caddy.** With `sse true`, `/events`
  answers `501`: anycable-go checks for `http.Flusher` directly, and Caddy's
  response writer doesn't satisfy that check. WebSockets (`/cable`, the
  normal ActionCable transport) work.
- The anycable-go version is fixed by caddy_anycable (v1.5.2). Newer
  anycable-go releases changed the API the plugin uses.
- Souin logs a warning that its default in-memory storage is meant for
  development. It works; for a shared or persistent cache, a storage module
  from [darkweak/storages](https://github.com/darkweak/storages) would need to
  be added to `variants/souin`.
- The official `caddy` base image can lag behind Caddy releases. Only the
  binary is replaced, so trust `caddy version`, not the base image tag.

## Building locally

```sh
./build.sh                # build and smoke-test all variants
./build.sh souin          # just one
tests/smoke.sh caddy8d:base base
```

Each variant is a small Go module in `variants/<name>/` (`main.go` imports the
plugins, `go.mod` pins their versions). To add a plugin, add its import to
`main.go` and run `go get <module>@latest && go mod tidy` in that directory.

## Licenses

This repository is licensed under the [AGPL-3.0](LICENSE). The images bundle
Caddy (Apache-2.0), Mercure (AGPL-3.0), and cbrotli, Souin and caddy_anycable
(MIT), all unmodified. This repository (the `go.mod`/`go.sum` files pin exact
versions) is the corresponding source.

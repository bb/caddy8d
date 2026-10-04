# caddy8d

Custom Caddy image for several servers, replacing an older self-built xcaddy
image. Base variant: Caddy + Mercure + caddy-cbrotli. Extra variants: `souin`, `anycable`. Images are
rebuilt automatically on every upstream stable release. User-facing docs, tags
and limitations live in README.md; it is also the Docker Hub description.
Sibling project with the same CI approach: github.com/bb/frankenpress.

## How it works

- `variants/<name>/{main.go,go.mod,go.sum}`: one Go module per variant, built
  with plain `go build` (Caddy's build-from-source method), selected by
  `--build-arg VARIANT`. Upstream releases arrive as Dependabot `gomod` PRs.
- `Dockerfile`: golang builder → official `caddy:*-alpine` with the binary
  replaced. Base images pinned by digest.
- `.github/workflows/docker.yml`: every run (PR, push, weekly, dispatch)
  builds, runs `tests/smoke.sh`, and only then pushes. PRs: amd64 only, no push.
  `create-manifests` derives tags from `caddy version` of the built image.
- `dependabot-automerge.yml` merges non-major Dependabot PRs once checks pass,
  then dispatches `docker.yml` (merges by GITHUB_TOKEN trigger nothing).

## Verification bar

A change is done when `./build.sh` (all three variants) ends with
`ALL CHECKS PASSED` for each. Smoke tests exercise each plugin for real
(publish/subscribe, cache hit, WebSocket broadcast), not just module presence.
When adding a check, run a negative control once to watch it go red; a check
that compared a constant string once passed for the wrong reason.

## Gotchas (each cost a debugging round)

- **xcaddy is avoided on purpose**: it pins Caddy to the builder image's
  version, so a plugin needing a newer Caddy breaks the build. That was why
  the old image no longer built (Mercure 1.0.3 needs Caddy ≥ 2.11.7, the
  builder had 2.11.6).
- **Mercure 1.0 is a protocol break.** 0.x Caddyfiles fail to start. We build
  with `GO_TAGS="deprecated_topic deprecated_claim deprecated_transport"`
  (like official Mercure builds) so servers can run
  `protocol_version_compatibility 8` until their apps migrate. Every hub after
  the first needs `name`. `examples/Caddyfile` is a migrated production config and
  the smoke test validates it, so a release that breaks this config fails CI.
- **anycable-go stays at v1.5.2**: caddy_anycable doesn't compile against
  v1.5.3+ (`config.Path` removed). Dependabot ignores it. caddy_anycable has
  no tags (pseudo-version).
- **AnyCable SSE returns 501 inside Caddy** (upstream: `w.(http.Flusher)`
  type assertion vs Caddy's wrapped writer). Tests use WebSockets only.
- AnyCable's HTTP broadcaster binds `127.0.0.1:8090`, so the test broadcasts
  via `docker exec` + busybox `wget`.
- `setcap` runs in the builder stage: doing it in the final stage duplicates
  the ~57MB binary in a new layer. The final stage asserts it with `getcap`.
- The official caddy image lags Caddy releases; that's expected (binary is
  replaced).
- Run tag/regex snippets under `bash` locally: the user's shell is zsh, where
  `BASH_REMATCH` is empty.

## Secrets

Never copy Caddyfiles from servers into the repo: they contain real Mercure
JWT keys. Use `{env.*}` placeholders and test-only keys.

## Status and plan

Done (2026-10-04): three variants build and pass smoke tests locally on
arm64 (Docker Desktop); workflows pass actionlint; pushed to github.com/bb/caddy8d.

Next:
1. Repo setup: secrets `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (optional
   `DOCKERHUB_DESCRIPTION_TOKEN`); create Docker Hub repo `bock/caddy8d`;
   branch protection on `main` requiring the `build` checks (auto-merge
   relies on it); allow GitHub Actions to create/approve PRs; enable
   Dependabot alerts/updates.
2. First CI run: confirm amd64 smoke tests and published tags.
3. Roll out on the first server: switch compose to `bock/caddy8d:2`, migrate its
   Caddyfile per `examples/Caddyfile` (keys into env), boot it, make a local request.
   If Mercure 1.0 can't open an old bolt DB, delete it (it only holds replay
   history).
4. Later: migrate the apps to Mercure 1.0 tokens/`match=` and drop
   compatibility mode; report the AnyCable SSE bug upstream.

Decided: image names `bock/caddy8d` and `ghcr.io/bb/caddy8d`; repository
license AGPL-3.0 (matches Mercure).

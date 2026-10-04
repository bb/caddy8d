#!/usr/bin/env bash
# Smoke test for a built caddy8d image.
#
# Usage: tests/smoke.sh <image> <base|souin|anycable>
#
# Starts the image with tests/caddy/<variant>.Caddyfile and checks that every
# bundled plugin works, not only that it is compiled in: Brotli encoding,
# Mercure publish/subscribe in 1.0 mode and in 0.x compatibility mode (bolt
# transport), plus the Souin cache or AnyCable, depending on the variant.
# Needs Docker, curl and openssl; exits non-zero if any check fails.
set -u
IMG=$1; VARIANT=$2; C=caddy8d-test-$$; NR=caddy8d-nonroot-$$; PORT=${PORT:-18080}
DIR=$(cd "$(dirname "$0")" && pwd); TMP=$(mktemp -d)
fail=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then printf "  ok    %-52s %s\n" "$1" "$3"; else printf "  FAIL  %-52s expected=%s got=%s\n" "$1" "$2" "$3"; fail=1; fi
}
cleanup() { docker rm -fv $C $NR >/dev/null 2>&1; jobs -p | xargs kill 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# HS256 JWT from a header and payload (JSON strings)
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() { # jwt <key> <header> <payload>
  local hp; hp="$(printf '%s' "$2" | b64url).$(printf '%s' "$3" | b64url)"
  printf '%s.%s' "$hp" "$(printf '%s' "$hp" | openssl dgst -sha256 -hmac "$1" -binary | b64url)"
}
PUB_KEY=test-publisher-key-not-a-secret-0123456789

echo "=== $IMG ($VARIANT)"
# --- static checks
modules=$(docker run --rm "$IMG" caddy list-modules --skip-standard 2>/dev/null)
has() { grep -qx "$1" <<<"$modules" && echo yes || echo no; }
check "caddy version" yes "$(docker run --rm "$IMG" caddy version | grep -qE '^v2\.[0-9]+\.[0-9]+ ' && echo yes || echo no)"
check "module http.handlers.mercure" yes "$(has http.handlers.mercure)"
check "module http.encoders.br" yes "$(has http.encoders.br)"
check "module http.handlers.cache (souin only)" "$([ "$VARIANT" = souin ] && echo yes || echo no)" "$(has http.handlers.cache)"
check "module http.handlers.anycable (anycable only)" "$([ "$VARIANT" = anycable ] && echo yes || echo no)" "$(has http.handlers.anycable)"
check "binary has cap_net_bind_service" yes "$(docker run --rm "$IMG" getcap /usr/bin/caddy | grep -q cap_net_bind_service && echo yes || echo no)"

# The production-style config (two named hubs in 0.x compatibility mode) must
# keep loading: a breaking Caddy or Mercure release shows up here first
check "examples/Caddyfile validates" yes "$(docker run --rm -e MERCURE_PUBLISHER_JWT_KEY=$PUB_KEY -e MERCURE_SUBSCRIBER_JWT_KEY=$PUB_KEY \
  -v "$DIR/../examples/Caddyfile:/etc/caddy/Caddyfile:ro" "$IMG" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && echo yes || echo no)"

# A non-root caddy can still bind port 80 (file capability survives the build)
docker run -d --name $NR --user 65534 -p $((PORT + 9)):80 "$IMG" caddy respond --listen :80 nonroot >/dev/null
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:$((PORT + 9))/" && break; sleep 0.5; done
check "non-root caddy binds port 80" nonroot "$(curl -s "http://localhost:$((PORT + 9))/")"
docker rm -f $NR >/dev/null

# --- runtime
docker run -d --name $C -p $PORT:80 -p $((PORT + 2)):8082 -v "$DIR/caddy:/etc/caddy:ro" "$IMG" \
  caddy run --config "/etc/caddy/$VARIANT.Caddyfile" >/dev/null
B=http://localhost:$PORT; CB=http://localhost:$((PORT + 2))
for _ in $(seq 1 30); do curl -s -o /dev/null $B/ && break; sleep 0.5; done
check "container running" true "$(docker inspect -f '{{.State.Running}}' $C)"
check "GET /" "hello from caddy8d" "$(curl -s $B/)"
check "brotli encoding" br "$(curl -s -H 'Accept-Encoding: br' -o /dev/null -w '%header{content-encoding}' $B/big)"
check "gzip encoding" gzip "$(curl -s -H 'Accept-Encoding: gzip' -o /dev/null -w '%header{content-encoding}' $B/big)"

# Mercure 1.0: OAuth access token (typ at+jwt) with authorization_details,
# subscribers use match=
now=$(date +%s)
token=$(jwt $PUB_KEY '{"alg":"HS256","typ":"at+jwt"}' "{\"iss\":\"https://issuer.test\",\"aud\":\"https://hub.test/.well-known/mercure\",\"sub\":\"smoke\",\"client_id\":\"smoke\",\"iat\":$now,\"exp\":$((now + 300)),\"jti\":\"smoke-$$\",\"authorization_details\":[{\"type\":\"https://mercure.rocks/authorization-detail\",\"actions\":[\"publish\"],\"topics\":[{\"match\":\"*\"}]}]}")
legacy=$(jwt $PUB_KEY '{"alg":"HS256","typ":"JWT"}' '{"mercure":{"publish":["*"]}}')
publish() { # publish <hub url> <token> <topic> <data> -> HTTP status
  curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $2" --data-urlencode "topic=$3" --data-urlencode "data=$4" "$1/.well-known/mercure"
}
subscribe() { # subscribe <url> <outfile>: SSE stream in the background
  curl -sN --max-time 10 "$1" > "$2" &
  sleep 1
}
subscribe "$B/.well-known/mercure?match=https://example.com/modern" "$TMP/modern.sse"
check "mercure 1.0: publish with access token" 200 "$(publish $B "$token" https://example.com/modern hello-modern)"
check "mercure 1.0: publish without token refused" 401 "$(curl -s -o /dev/null -w '%{http_code}' -d topic=x -d data=y $B/.well-known/mercure)"
check "mercure 1.0: legacy 0.x token refused" 401 "$(publish $B "$legacy" https://example.com/modern nope)"
sleep 1
check "mercure 1.0: subscriber receives update" yes "$(grep -q '^data: hello-modern$' "$TMP/modern.sse" && echo yes || echo no)"

# Mercure 0.x compatibility (the hub built with the deprecated_* tags):
# `mercure` claim tokens and topic= subscriptions keep working
subscribe "$CB/.well-known/mercure?topic=https://example.com/compat" "$TMP/compat.sse"
check "mercure compat: publish with 0.x token" 200 "$(publish $CB "$legacy" https://example.com/compat hello-compat)"
sleep 1
check "mercure compat: topic= subscriber receives update" yes "$(grep -q '^data: hello-compat$' "$TMP/compat.sse" && echo yes || echo no)"
check "mercure bolt databases written" yes "$(docker exec $C sh -c 'test -s /data/mercure.db && test -s /data/mercure-compat.db' && echo yes || echo no)"

if [ "$VARIANT" = souin ]; then
  first=$(curl -s $B/cached); second=$(curl -s -D "$TMP/h" $B/cached)
  check "souin: second request served from cache" "$first" "$second"
  check "souin: Cache-Status reports a hit" yes "$(grep -i '^cache-status:' "$TMP/h" | grep -qi 'hit' && echo yes || echo no)"
fi

if [ "$VARIANT" = anycable ]; then
  check "anycable: websocket upgrade on /cable" 101 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Protocol: actioncable-v1-json' $B/cable)"
  # Public mode: an ActionCable client subscribes to a stream over WebSocket,
  # then a broadcast to the HTTP broadcaster (reachable only inside the
  # container) must reach it
  cable=$(python3 - "$PORT" "$C" <<'PY'
import base64, json, os, socket, struct, subprocess, sys
port, container = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("localhost", port), timeout=5)
s.sendall((f"GET /cable HTTP/1.1\r\nHost: localhost:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}\r\nSec-WebSocket-Version: 13\r\n"
           "Sec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]
def recv_exact(n):
    global buf
    while len(buf) < n:
        chunk = s.recv(4096)
        if not chunk:
            raise EOFError
        buf += chunk
    out, buf = buf[:n], buf[n:]
    return out
def recv():  # next JSON text frame (server frames are unmasked)
    while True:
        b0, b1 = recv_exact(2)
        n = b1 & 0x7F
        if n == 126: n = struct.unpack(">H", recv_exact(2))[0]
        elif n == 127: n = struct.unpack(">Q", recv_exact(8))[0]
        data = recv_exact(n)
        if b0 & 0x0F == 1:
            return json.loads(data)
def send(obj):  # client frames must be masked
    data, mask = json.dumps(obj).encode(), os.urandom(4)
    hdr = bytes([0x81, 0x80 | len(data)]) if len(data) < 126 else bytes([0x81, 0xFE]) + struct.pack(">H", len(data))
    s.sendall(hdr + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))
def until(pred):
    while True:
        m = recv()
        if pred(m):
            return m
try:
    until(lambda m: m.get("type") == "welcome")
    ident = json.dumps({"channel": "$pubsub", "stream_name": "smoke"})
    send({"command": "subscribe", "identifier": ident})
    until(lambda m: m.get("type") == "confirm_subscription")
    subprocess.run(["docker", "exec", container, "wget", "-q", "-O", "/dev/null", "--header", "Content-Type: application/json",
                    "--post-data", json.dumps({"stream": "smoke", "data": json.dumps({"text": "hello-cable"})}),
                    "http://127.0.0.1:8090/_broadcast"], check=True)
    print(until(lambda m: "message" in m)["message"]["text"])
except Exception as e:
    print(f"error: {e!r}")
PY
)
  check "anycable: websocket subscriber receives broadcast" hello-cable "$cable"
fi

errs=$(docker logs $C 2>&1 | grep '"level":"error"' | head -3)
check "no errors in container log" "" "$errs"
[ $fail = 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; docker logs $C 2>&1 | tail -20; }
exit $fail

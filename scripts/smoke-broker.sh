#!/usr/bin/env bash
# Broker liveness smoke test (TRA-835).
#
# Subscribe to '#' over TLS 1.2, publish a ping with a unique payload,
# assert the subscriber receives it. One round-trip exercises:
#   - LoadBalancer reachable
#   - TLS handshake (valid cert from a public CA)
#   - TLS 1.2 negotiates (matches the GL-S10 pinned version)
#   - Auth accepted
#   - Broker routes pub -> sub
#
# Cross-cloud: parameterize the host so one script serves every cluster.
#   scripts/smoke-broker.sh -h mqtt.gke.trakrf.id
#   scripts/smoke-broker.sh -h mqtt.eks.trakrf.id
#   scripts/smoke-broker.sh -h mqtt.aks.trakrf.id
#
# Credentials come from env (never hardcoded):
#   MQTT_HOST         broker hostname  (or -h)
#   MQTT_PORT         broker port      (default 8883)
#   MQTT_USER         username         (or -u)
#   MQTT_PASS         password         (or -P)
#   MQTT_SUB_TOPIC    subscribe topic  (default '#'; override for ACL-restricted brokers, e.g. 'trakrf.id/#')
#   MQTT_PUB_PREFIX   publish prefix   (default 'smoke/ping'; full topic is "$PREFIX/$NONCE")
#
# Requires: mosquitto-clients (mosquitto_pub, mosquitto_sub).

set -euo pipefail

PORT="${MQTT_PORT:-8883}"
HOST="${MQTT_HOST:-}"
USER="${MQTT_USER:-}"
PASS="${MQTT_PASS:-}"
TIMEOUT="${MQTT_TIMEOUT:-10}"
SUB_TOPIC="${MQTT_SUB_TOPIC:-#}"
PUB_PREFIX="${MQTT_PUB_PREFIX:-smoke/ping}"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts "h:p:u:P:t:S:T:?" opt; do
  case "$opt" in
    h) HOST="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    P) PASS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    S) SUB_TOPIC="$OPTARG" ;;
    T) PUB_PREFIX="$OPTARG" ;;
    \?) usage 0 ;;
    *) usage 1 ;;
  esac
done

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

[[ -n "$HOST" ]] || fail "MQTT_HOST not set (use -h or export MQTT_HOST)"
[[ -n "$USER" ]] || fail "MQTT_USER not set (use -u or export MQTT_USER)"
[[ -n "$PASS" ]] || fail "MQTT_PASS not set (use -P or export MQTT_PASS)"
command -v mosquitto_sub >/dev/null || fail "mosquitto_sub not found (install mosquitto-clients)"
command -v mosquitto_pub >/dev/null || fail "mosquitto_pub not found (install mosquitto-clients)"

NONCE="$(date -u +%s)-$$-$RANDOM"
TOPIC="$PUB_PREFIX/$NONCE"
PAYLOAD="ping-$NONCE"
OUT="$(mktemp)"
SUB_PID=""

cleanup() {
  if [[ -n "$SUB_PID" ]] && kill -0 "$SUB_PID" 2>/dev/null; then
    kill "$SUB_PID" 2>/dev/null || true
    wait "$SUB_PID" 2>/dev/null || true
  fi
  rm -f "$OUT"
}
trap cleanup EXIT

echo "→ Subscribing to '$SUB_TOPIC' on $HOST:$PORT over TLS 1.2..."
mosquitto_sub \
  -h "$HOST" -p "$PORT" \
  -u "$USER" -P "$PASS" \
  --tls-version tlsv1.2 \
  -t "$SUB_TOPIC" \
  -W "$TIMEOUT" \
  -v \
  >"$OUT" 2>&1 &
SUB_PID=$!

# Give the subscriber time to connect + subscribe before we publish.
# mosquitto_sub doesn't expose a "subscribed" signal; a short sleep is
# the conventional wait. If the subscriber failed to start, the publish
# below will still succeed but we won't see the message, and the final
# assertion will fail with the captured stderr.
sleep 2

if ! kill -0 "$SUB_PID" 2>/dev/null; then
  echo "--- subscriber output ---" >&2
  cat "$OUT" >&2
  fail "subscriber exited before publish (see output above)"
fi

echo "→ Publishing $PAYLOAD to $TOPIC..."
mosquitto_pub \
  -h "$HOST" -p "$PORT" \
  -u "$USER" -P "$PASS" \
  --tls-version tlsv1.2 \
  -t "$TOPIC" \
  -m "$PAYLOAD" \
  || fail "publish failed"

# Poll the subscriber's output for our payload.
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while (( $(date +%s) < DEADLINE )); do
  if grep -qF "$TOPIC $PAYLOAD" "$OUT"; then
    pass "round-trip received on $HOST:$PORT (tlsv1.2, $TOPIC)"
    exit 0
  fi
  sleep 0.5
done

echo "--- subscriber output ---" >&2
cat "$OUT" >&2
fail "subscriber did not receive $PAYLOAD within ${TIMEOUT}s"

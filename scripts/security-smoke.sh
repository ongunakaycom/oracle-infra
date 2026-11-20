#!/usr/bin/env bash
# Runtime security smoke suite for the SecOps API.
#
# The suite drives authentication, CORS, input limits and the login rate
# limiter against a *local* instance. It refuses non-loopback targets on
# purpose: production is health-check-only and must never receive negative
# traffic (the limiter is per IP, the instance has 1 GB of RAM, and the deploy
# workflow probes the same process).
#
# Usage:
#   # build and start backend/ on 127.0.0.1:8080, then run every check
#   SECOPS_SMOKE_AUTOSTART=1 bash scripts/security-smoke.sh
#
#   # run against an already running local API
#   BASE_URL=http://127.0.0.1:8080 bash scripts/security-smoke.sh
#
# Environment:
#   BASE_URL              target, default http://127.0.0.1:8080 (loopback only)
#   SECOPS_ADMIN_USER     credentials used for the happy path (default smoke-admin)
#   SECOPS_ADMIN_PASS     credentials used for the happy path (default smoke-pass)
#   SMOKE_ALLOWED_ORIGIN  origin the target is expected to allow
#                         (default http://localhost:5173)
#   SECOPS_SMOKE_AUTOSTART 1 = build and start backend/ before testing
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
BASE_URL="${BASE_URL%/}"
ADMIN_USER="${SECOPS_ADMIN_USER:-smoke-admin}"
ADMIN_PASS="${SECOPS_ADMIN_PASS:-smoke-pass}"
ALLOWED_ORIGIN="${SMOKE_ALLOWED_ORIGIN:-http://localhost:5173}"
AUTOSTART="${SECOPS_SMOKE_AUTOSTART:-0}"

TMP="$(mktemp -d)"
SERVER_PID=""
CHECKS=0
FAILURES=0

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -f "$TMP/server.log" ]; then
    echo
    echo "--- backend log (last 40 lines) ---"
    tail -n 40 "$TMP/server.log" || true
  fi
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() {
  CHECKS=$((CHECKS + 1))
  printf '  ok   %s\n' "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf '  FAIL %s\n' "$1"
}

# expect_status <description> <expected> <actual>
expect_status() {
  if [ "$2" = "$3" ]; then
    pass "$1 (HTTP $3)"
  else
    fail "$1 (expected HTTP $2, got $3)"
  fi
}

# expect_equal <description> <expected> <actual>
expect_equal() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected '$2', got '$3')"
  fi
}

# request <method> <path> <output-prefix> [curl args...]
# Writes <prefix>.body and <prefix>.headers, prints the status code.
request() {
  local method="$1" path="$2" out="$3"
  shift 3
  mkdir -p "$(dirname "$out")"
  curl -sS --max-time 10 -o "${out}.body" -D "${out}.headers" \
    -w '%{http_code}' -X "$method" "${BASE_URL}${path}" "$@"
}

# header_value <headers-file> <lowercase-header-name>
header_value() {
  awk -v want="$2" '
    BEGIN { FS = ":" }
    tolower($1) == want {
      value = $0
      sub(/^[^:]*:[ \t]*/, "", value)
      sub(/[ \t\r]+$/, "", value)
    }
    END { if (value != "") print value }
  ' "$1"
}

# json_token <body-file>
json_token() {
  sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# ---- Target guard ----------------------------------------------------------

host="${BASE_URL#*://}"
host="${host%%/*}"
host="${host%%:*}"
case "$host" in
  127.0.0.1 | localhost | ::1) ;;
  *)
    echo "refusing to run: BASE_URL must point at a local instance (got ${BASE_URL})." >&2
    echo "Production is health-check-only; test a local backend instead." >&2
    exit 2
    ;;
esac

if [ "$AUTOSTART" = "1" ] && [ "$BASE_URL" != "http://127.0.0.1:8080" ]; then
  echo "autostart only supports http://127.0.0.1:8080 (backend/main.go hard-codes the port)." >&2
  echo "Start the API yourself and rerun with BASE_URL=${BASE_URL}." >&2
  exit 2
fi

# ---- Optional autostart ----------------------------------------------------

if [ "$AUTOSTART" = "1" ]; then
  if curl -fsS --max-time 2 "${BASE_URL}/api/health" >/dev/null 2>&1; then
    echo "refusing to autostart: ${BASE_URL} already answers. Stop that process first." >&2
    exit 2
  fi

  echo "Building backend/ ..."
  (cd "$REPO_ROOT/backend" && go build -o "$TMP/secops-api" .)

  # Never hard-code a key in the repository; generate a throwaway one.
  JWT_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  (
    cd "$REPO_ROOT/backend"
    SECOPS_ADMIN_USER="$ADMIN_USER" \
      SECOPS_ADMIN_PASS="$ADMIN_PASS" \
      SECOPS_JWT_SECRET="$JWT_SECRET" \
      SECOPS_DB_PATH="$TMP/smoke.db" \
      ALLOWED_ORIGINS="$ALLOWED_ORIGIN" \
      exec "$TMP/secops-api"
  ) >"$TMP/server.log" 2>&1 &
  SERVER_PID=$!

  ready=0
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 "${BASE_URL}/api/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      break
    fi
    sleep 0.5
  done
  if [ "$ready" -ne 1 ]; then
    echo "backend did not become ready on ${BASE_URL}" >&2
    exit 1
  fi
  echo "backend ready (pid ${SERVER_PID})"
fi

printf 'security smoke target: %s\n\n' "$BASE_URL"

# ---- 1. Health & response shape -------------------------------------------

echo "== health =="
code=$(request GET /api/health "$TMP/health")
expect_status "GET /api/health" 200 "$code"
if grep -q '"status":"HEALTHY"' "$TMP/health.body"; then
  pass "health payload reports HEALTHY"
else
  fail "health payload reports HEALTHY"
fi
expect_equal "health responds as JSON" "application/json" \
  "$(header_value "$TMP/health.headers" content-type)"

# ---- 2. CORS allowlist ----------------------------------------------------

echo "== CORS =="
code=$(request GET /api/health "$TMP/cors-evil" -H 'Origin: https://evil.example')
expect_status "foreign origin is served but unprivileged" 200 "$code"
expect_equal "foreign origin gets no Access-Control-Allow-Origin" "" \
  "$(header_value "$TMP/cors-evil.headers" access-control-allow-origin)"

code=$(request OPTIONS /api/login "$TMP/cors-ok" \
  -H "Origin: ${ALLOWED_ORIGIN}" \
  -H 'Access-Control-Request-Method: POST')
expect_status "preflight from allowlisted origin" 204 "$code"
expect_equal "allowlisted origin is echoed back" "$ALLOWED_ORIGIN" \
  "$(header_value "$TMP/cors-ok.headers" access-control-allow-origin)"

# ---- 3. Authentication gate ----------------------------------------------

echo "== authentication gate =="
code=$(request GET /api/metrics "$TMP/metrics-anon")
expect_status "GET /api/metrics without token" 401 "$code"
code=$(request GET /api/records "$TMP/records-anon")
expect_status "GET /api/records without token" 401 "$code"

# ---- 4. Login and authorized calls ---------------------------------------

echo "== login & authorized requests =="
code=$(request POST /api/login "$TMP/login-ok" \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: 203.0.113.20' \
  --data-binary "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}")
expect_status "POST /api/login with valid credentials" 200 "$code"

token="$(json_token "$TMP/login-ok.body")"
if [ -n "$token" ]; then
  pass "login returns a bearer token"

  code=$(request GET /api/metrics "$TMP/metrics" \
    -H "Authorization: Bearer ${token}")
  expect_status "GET /api/metrics with token" 200 "$code"

  code=$(request GET /api/records "$TMP/records" \
    -H "Authorization: Bearer ${token}")
  expect_status "GET /api/records with token" 200 "$code"

  code=$(request POST /api/records "$TMP/record-create" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    --data-binary '{"service":"smoke","severity":"LOW","message":"security smoke test"}')
  expect_status "POST /api/records accepts valid payload" 201 "$code"

  code=$(request POST /api/records "$TMP/record-bad-severity" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    --data-binary '{"service":"smoke","severity":"CRITICAL","message":"invalid severity"}')
  expect_status "POST /api/records rejects unknown severity" 400 "$code"

  code=$(request GET '/api/records?q=%27%20OR%201%3D1--' "$TMP/record-search" \
    -H "Authorization: Bearer ${token}")
  expect_status "GET /api/records tolerates quoted search input" 200 "$code"

  # Flip the last character of the signature: still well-formed, wrong key.
  last="${token: -1}"
  if [ "$last" = "A" ]; then
    replacement="B"
  else
    replacement="A"
  fi
  tampered="${token%?}${replacement}"
  code=$(request GET /api/metrics "$TMP/tampered" \
    -H "Authorization: Bearer ${tampered}")
  expect_status "tampered token is rejected" 401 "$code"
else
  fail "login returns a bearer token (empty token in response)"
  fail "authorized request checks were skipped (no token)"
fi

# ---- 5. Login rate limiter -----------------------------------------------

echo "== login rate limiter =="
for attempt in 1 2 3 4 5; do
  code=$(request POST /api/login "$TMP/limit-${attempt}" \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 203.0.113.10' \
    --data-binary '{"username":"nobody","password":"wrong"}')
  expect_status "failed login ${attempt}/5" 401 "$code"
done

code=$(request POST /api/login "$TMP/limit-6" \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: 203.0.113.10' \
  --data-binary '{"username":"nobody","password":"wrong"}')
expect_status "6th failed login is throttled" 429 "$code"

retry_after="$(header_value "$TMP/limit-6.headers" retry-after)"
case "$retry_after" in
  '' | *[!0-9]*)
    fail "429 carries a numeric Retry-After header (got '${retry_after}')"
    ;;
  *)
    if [ "$retry_after" -ge 1 ]; then
      pass "429 carries Retry-After=${retry_after}s"
    else
      fail "429 carries a Retry-After of at least one second (got ${retry_after})"
    fi
    ;;
esac

# A different client IP must not inherit the lockout.
code=$(request POST /api/login "$TMP/limit-other-ip" \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: 203.0.113.11' \
  --data-binary "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}")
expect_status "lockout is scoped to the offending IP" 200 "$code"

# ---- 6. Request limits ---------------------------------------------------

echo "== request limits =="
{
  printf '{"username":"x","password":"'
  head -c 8000 /dev/zero | tr '\0' 'a'
  printf '"}'
} >"$TMP/big-login.json"

code=$(request POST /api/login "$TMP/big-login" \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: 203.0.113.30' \
  --data-binary "@$TMP/big-login.json")
expect_status "oversized login body is rejected" 400 "$code"

code=$(request GET /api/login "$TMP/login-method")
expect_status "GET /api/login is rejected" 405 "$code"

# ---- Summary -------------------------------------------------------------

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "security smoke: ${FAILURES}/${CHECKS} checks failed" >&2
  exit 1
fi
echo "security smoke: all ${CHECKS} checks passed"

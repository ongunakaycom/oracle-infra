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
#   SECOPS_SMOKE_JWT_SECRET  signing key of the target, needed to mint
#                         validly-signed edge-case tokens. Optional: the
#                         alg:none / unsupported-algorithm checks run without
#                         it, but the expired / future-dated claim checks are
#                         skipped when the key is unknown.
#   SECOPS_SMOKE_AUTOSTART 1 = build and start backend/ before testing
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
BASE_URL="${BASE_URL%/}"
ADMIN_USER="${SECOPS_ADMIN_USER:-smoke-admin}"
ADMIN_PASS="${SECOPS_ADMIN_PASS:-smoke-pass}"
ALLOWED_ORIGIN="${SMOKE_ALLOWED_ORIGIN:-http://localhost:5173}"
AUTOSTART="${SECOPS_SMOKE_AUTOSTART:-0}"
SMOKE_JWT_SECRET="${SECOPS_SMOKE_JWT_SECRET:-}"

# Distinctive, low-entropy marker used as a wrong password. It must never show
# up in audit_logs; the value is asserted below.
WRONG_PASS="smoke-wrong-password"

TMP="$(mktemp -d)"
SERVER_PID=""
TOKEN=""
HAS_TOKEN=0
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

# b64url_encode <string>
# base64url without padding. GNU base64 wraps output at 76 columns, and a raw
# newline inside an HTTP header makes Go answer 400 Bad Request before the
# handler runs, so the newline is stripped here. This is what silently broke
# the first revision of the JWT checks.
b64url_encode() {
  printf '%s' "$1" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

# hmac_sha256_b64url <secret>  (signing input on stdin)
hmac_sha256_b64url() {
  openssl dgst -sha256 -hmac "$1" -binary | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

# mint_jwt <secret> <header-json> <payload-json>
# Builds a signed HS256 token. Used to prove that expired / future-dated
# tokens carrying a *cryptographically valid* signature are still rejected:
# a token that fails on the signature alone would not exercise claim checks.
mint_jwt() {
  local secret="$1" header payload signing
  header="$(b64url_encode "$2")"
  payload="$(b64url_encode "$3")"
  signing="${header}.${payload}"
  printf '%s.%s.%s' "$header" "$payload" \
    "$(printf '%s' "$signing" | hmac_sha256_b64url "$secret")"
}

# fetch_audit_log <token> [search-term]
# Reads audit_logs back through the authorised API (no sqlite3 dependency) and
# stores the JSON array in $TMP/audit.json. Prints the status code.
fetch_audit_log() {
  curl -sS --max-time 10 -o "$TMP/audit.json" -w '%{http_code}' -G \
    --data-urlencode "q=${2:-}" "${BASE_URL}/api/records" \
    -H "Authorization: Bearer $1"
}

# audit_kv_count <service-substring> <severity-substring> <message-substring>
# Counts records in the last fetched page that carry all three strings.
audit_kv_count() {
  tr '}' '\n' <"$TMP/audit.json" |
    grep -F "\"service\":\"$1\"" |
    grep -F "\"severity\":\"$2\"" |
    grep -cF "$3" || true
}

# audit_note_count <substring>
# Counts records in the last fetched page that carry the given string at all.
audit_note_count() {
  tr '}' '\n' <"$TMP/audit.json" | grep -cF "$1" || true
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
  # The suite knows the key it just generated, so it can mint signed tokens
  # to prove the claim (exp/nbf/iat) validation, not only the signature check.
  SMOKE_JWT_SECRET="$JWT_SECRET"

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
  TOKEN="$token"
  HAS_TOKEN=1
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

# ---- 5. JWT validation ---------------------------------------------------

# The signature gate is already covered by the tampered-token check above.
# These cases prove the *claim* and *algorithm* handling, which is where JWT
# implementations usually go wrong:
#   * alg:none / algorithm confusion (header is attacker-controlled),
#   * expired tokens,
#   * tokens dated in the future (iat / nbf) - a sign of a forged or
#     clock-skewed token.
# Claims are only reached when the signature verifies, so the empty-key and
# future-dated checks mint a genuinely signed token first.
echo "== JWT validation =="

now="$(date +%s)"
HS256_HEADER='{"alg":"HS256","typ":"JWT"}'

# 1. alg:none with an empty signature (the classic forgery).
none_token="$(b64url_encode '{"alg":"none","typ":"JWT"}').$(b64url_encode "{\"sub\":\"smoke-admin\",\"role\":\"admin\",\"iat\":${now},\"exp\":$((now + 3600))}")."
code=$(request GET /api/metrics "$TMP/jwt-alg-none" \
  -H "Authorization: Bearer ${none_token}")
expect_status "token with alg:none is rejected" 401 "$code"

# 2. Unsupported algorithm (HS512) - only HS256 is accepted, so an otherwise
#    correctly signed token of another family must not be honoured.
if command -v openssl >/dev/null 2>&1 && [ -n "$SMOKE_JWT_SECRET" ]; then
  hs512_header="$(b64url_encode '{"alg":"HS512","typ":"JWT"}')"
  hs512_payload="$(b64url_encode "{\"sub\":\"smoke-admin\",\"role\":\"admin\",\"iat\":${now},\"exp\":$((now + 3600))}")"
  hs512_sig="$(printf '%s' "${hs512_header}.${hs512_payload}" \
    | openssl dgst -sha512 -hmac "$SMOKE_JWT_SECRET" -binary | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
  code=$(request GET /api/metrics "$TMP/jwt-hs512" \
    -H "Authorization: Bearer ${hs512_header}.${hs512_payload}.${hs512_sig}")
  expect_status "token with unsupported alg:HS512 is rejected" 401 "$code"

  # 3. Positive control: a validly minted token must be accepted. Without this
  #    the negative results above could pass merely because minting is broken.
  control_token="$(mint_jwt "$SMOKE_JWT_SECRET" "$HS256_HEADER" \
    "{\"sub\":\"smoke-admin\",\"role\":\"admin\",\"iat\":${now},\"exp\":$((now + 3600))}")"
  code=$(request GET /api/metrics "$TMP/jwt-control" \
    -H "Authorization: Bearer ${control_token}")
  expect_status "freshly minted valid token is accepted (control)" 200 "$code"

  # 4. Expired token: valid signature, exp in the past.
  expired_token="$(mint_jwt "$SMOKE_JWT_SECRET" "$HS256_HEADER" \
    "{\"sub\":\"smoke-admin\",\"role\":\"admin\",\"iat\":$((now - 7200)),\"exp\":$((now - 3600))}")"
  code=$(request GET /api/metrics "$TMP/jwt-expired" \
    -H "Authorization: Bearer ${expired_token}")
  expect_status "expired token is rejected" 401 "$code"

  # 5. Future iat: token claims it was issued an hour from now.
  future_iat_token="$(mint_jwt "$SMOKE_JWT_SECRET" "$HS256_HEADER" \
    "{\"sub\":\"smoke-admin\",\"role\":\"admin\",\"iat\":$((now + 3600)),\"exp\":$((now + 7200))}")"
  code=$(request GET /api/metrics "$TMP/jwt-future-iat" \
    -H "Authorization: Bearer ${future_iat_token}")
  expect_status "token with future iat is rejected" 401 "$code"

  # 6. Future nbf: token is not valid until an hour from now.
  future_nbf_token="$(mint_jwt "$SMOKE_JWT_SECRET" "$HS256_HEADER" \
    "{\"sub\":\"smoke-admin\",\"role\":\"admin\",\"iat\":${now},\"nbf\":$((now + 3600)),\"exp\":$((now + 7200))}")"
  code=$(request GET /api/metrics "$TMP/jwt-future-nbf" \
    -H "Authorization: Bearer ${future_nbf_token}")
  expect_status "token with future nbf is rejected" 401 "$code"

  # 7. Correct algorithm, wrong key: signature must fail.
  wrong_key_token="$(mint_jwt "not-the-real-key" "$HS256_HEADER" \
    "{\"sub\":\"smoke-admin\",\"role\":\"admin\",\"iat\":${now},\"exp\":$((now + 3600))}")"
  code=$(request GET /api/metrics "$TMP/jwt-wrong-key" \
    -H "Authorization: Bearer ${wrong_key_token}")
  expect_status "token signed with the wrong key is rejected" 401 "$code"
else
  pass "signed-token claim checks skipped (no signing key available to the suite)"
fi

# 8. Malformed token: not three dot-separated parts.
code=$(request GET /api/metrics "$TMP/jwt-malformed" \
  -H "Authorization: Bearer not-a-jwt")
expect_status "malformed token is rejected" 401 "$code"

# ---- 6. Security headers -------------------------------------------------

# Hardening headers are also set by the Caddy edge (backend/Caddyfile), but the
# API must carry them itself so the guarantees survive direct :8080 access and
# local/CI runs where Caddy is absent. Asserting on an authorised resource, a
# public endpoint and an error response proves the middleware is not skipped.
echo "== security headers =="
code=$(request GET /api/health "$TMP/headers-health")
expect_status "GET /api/health for headers" 200 "$code"

expect_equal "X-Content-Type-Options: nosniff" "nosniff" \
  "$(header_value "$TMP/headers-health.headers" x-content-type-options)"
expect_equal "X-Frame-Options: DENY" "DENY" \
  "$(header_value "$TMP/headers-health.headers" x-frame-options)"
expect_equal "Referrer-Policy: strict-origin-when-cross-origin" \
  "strict-origin-when-cross-origin" \
  "$(header_value "$TMP/headers-health.headers" referrer-policy)"
expect_equal "Cross-Origin-Resource-Policy: same-origin" "same-origin" \
  "$(header_value "$TMP/headers-health.headers" cross-origin-resource-policy)"

csp="$(header_value "$TMP/headers-health.headers" content-security-policy)"
if printf '%s' "$csp" | grep -q "frame-ancestors 'none'"; then
  pass "Content-Security-Policy denies framing"
else
  fail "Content-Security-Policy denies framing (got '${csp}')"
fi

perms="$(header_value "$TMP/headers-health.headers" permissions-policy)"
if printf '%s' "$perms" | grep -q 'geolocation=()'; then
  pass "Permissions-Policy restricts powerful features"
else
  fail "Permissions-Policy restricts powerful features (got '${perms}')"
fi

# Headers must also be present on 401 (auth gate) and 405 (wrong method)
# responses; a header middleware wired only around success paths is a common
# mistake.
code=$(request GET /api/metrics "$TMP/headers-401")
expect_status "unauthenticated request is rejected (header probe)" 401 "$code"
expect_equal "401 responses still carry nosniff" "nosniff" \
  "$(header_value "$TMP/headers-401.headers" x-content-type-options)"

code=$(request GET /api/login "$TMP/headers-405")
expect_status "GET /api/login is rejected (header probe)" 405 "$code"
expect_equal "405 responses still carry nosniff" "nosniff" \
  "$(header_value "$TMP/headers-405.headers" x-content-type-options)"

# ---- 7. Login rate limiter -----------------------------------------------

echo "== login rate limiter =="
for attempt in 1 2 3 4 5; do
  code=$(request POST /api/login "$TMP/limit-${attempt}" \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 203.0.113.10' \
    --data-binary "{\"username\":\"nobody\",\"password\":\"${WRONG_PASS}\"}")
  expect_status "failed login ${attempt}/5" 401 "$code"
done

code=$(request POST /api/login "$TMP/limit-6" \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: 203.0.113.10' \
  --data-binary "{\"username\":\"nobody\",\"password\":\"${WRONG_PASS}\"}")
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

# ---- 8. Request limits ---------------------------------------------------

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

# ---- 9. Audit trail ------------------------------------------------------

# Endpoint behaviour alone does not prove anything was recorded. These checks
# read audit_logs back through the API and assert the security events landed
# there exactly once, with the real client IP and without credential leakage.
echo "== audit trail =="
if [ "$HAS_TOKEN" -ne 1 ]; then
  fail "audit trail assertions skipped (no admin token)"
else
  status=$(fetch_audit_log "$TOKEN")
  expect_status "GET /api/records reads the audit trail" 200 "$status"

  expect_equal "successful login is audited once (INFO, real client IP)" "1" \
    "$(audit_kv_count auth-gateway INFO 'Operator login succeeded from 203.0.113.20')"

  expect_equal "the failing IP has no success record" "0" \
    "$(audit_kv_count auth-gateway INFO '203.0.113.10')"

  expect_equal "lockout is audited exactly once (WARN)" "1" \
    "$(audit_kv_count auth-gateway WARN 'Login rate limit engaged for 203.0.113.10 after 5 failed attempts')"

  expect_equal "individual failed logins do not flood audit_logs" "0" \
    "$(audit_kv_count auth-gateway WARN '203.0.113.11')"

  expect_equal "one oversized body stays below the audit threshold" "0" \
    "$(audit_kv_count auth-gateway WARN '203.0.113.30')"

  expect_equal "submitted passwords never reach audit_logs" "0" \
    "$(audit_note_count "$WRONG_PASS")"

  if [ "${#ADMIN_PASS}" -ge 6 ]; then
    expect_equal "the configured admin password never reaches audit_logs" "0" \
      "$(audit_note_count "$ADMIN_PASS")"
  else
    pass "admin password leak check skipped (password shorter than 6 characters)"
  fi

  # Throttled retries must not append a new WARN row per request.
  code=$(request POST /api/login "$TMP/limit-7" \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 203.0.113.10' \
    --data-binary "{\"username\":\"nobody\",\"password\":\"${WRONG_PASS}\"}")
  expect_status "7th failed login stays throttled" 429 "$code"

  fetch_audit_log "$TOKEN" >/dev/null
  expect_equal "throttled retries do not duplicate the WARN row" "1" \
    "$(audit_kv_count auth-gateway WARN 'Login rate limit engaged for 203.0.113.10')"
fi

# ---- Summary -------------------------------------------------------------

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "security smoke: ${FAILURES}/${CHECKS} checks failed" >&2
  exit 1
fi
echo "security smoke: all ${CHECKS} checks passed"

#!/usr/bin/env bash
#
# Verify the live TLS configuration end to end.
#
#   ./scripts/domain-ssl-validate.sh [domain]
#
# Checks the certificate actually served, the expiry, the redirect, and that
# the application reports HTTPS. Read-only.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

DOMAIN_ARG="${1:-$(env_value DOMAIN '')}"
[[ -z "$DOMAIN_ARG" ]] && die "no domain configured; pass one or set DOMAIN in docker/.env"

require_cmd curl

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((FAILURES+1)); }

step "1. resolving $DOMAIN_ARG"
if getent hosts "$DOMAIN_ARG" >/dev/null 2>&1; then
    pass "resolves to $(getent hosts "$DOMAIN_ARG" | awk '{print $1}' | head -n1 | tr '\n' ' ')"
else
    fail "does not resolve. Add an A record pointing at this host first."
    exit 1
fi

step "2. serving certificate"
if cert="$(echo | timeout 15 openssl s_client -connect "$DOMAIN_ARG:443" -servername "$DOMAIN_ARG" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate 2>/dev/null)"; then
    printf '%s\n' "$cert" | sed 's/^/    /'
    if grep -q "$DOMAIN_ARG" <<<"$cert"; then
        pass "certificate is valid for $DOMAIN_ARG"
    else
        fail "certificate does not match $DOMAIN_ARG"
    fi
else
    fail "could not complete a TLS handshake on :443"
fi

step "3. expiry"
if openssl s_client -connect "$DOMAIN_ARG:443" -servername "$DOMAIN_ARG" </dev/null 2>/dev/null \
     | openssl x509 -noout -checkend 2592000 >/dev/null 2>&1; then
    pass "valid for more than 30 days"
else
    fail "expires within 30 days, or could not be determined -- renew it"
fi

step "4. HTTP redirect"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$DOMAIN_ARG/" || echo 000)"
if [[ "$code" =~ ^30[12378]$ ]]; then
    pass "http:// redirects ($code)"
else
    fail "http:// returned $code, expected a redirect to https"
fi

step "5. application over https"
if curl -fsS --max-time 10 "https://$DOMAIN_ARG/api/health" >/dev/null 2>&1; then
    pass "GET /api/health over https"
else
    fail "https API health check failed"
fi

if (( FAILURES == 0 )); then
    printf '\n\033[32mTLS is correctly configured.\033[0m\n'; exit 0
else
    printf '\n\033[31m%d TLS check(s) failed.\033[0m\n' "$FAILURES"; exit 1
fi

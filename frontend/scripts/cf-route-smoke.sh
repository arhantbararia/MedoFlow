#!/usr/bin/env bash
# Route smoke test for the deployed frontend (D1.1 / D1.4).
#   bash frontend/scripts/cf-route-smoke.sh [base-url]
# Walks every app/**/page.tsx, fills dynamic segments with a sample id, and
# requests each route. Fails if any route returns >= 400 or an adapter error page.
# Also verifies the /dashboard/patient/* -> /account/* redirects from next.config.js.
set -uo pipefail
BASE="${1:-https://medoflow-web.advertout-medoflow.workers.dev}"
cd "$(dirname "$0")/../app" || exit 1

fail=0
total=0
while IFS= read -r page; do
  route="/$(dirname "$page")"
  route="$(echo "$route" | sed -E 's#/\([^)]*\)##g; s#\[[^]]+\]#sample-id#g; s#^/\.$#/#; s#/\.$##')"
  [ -z "$route" ] && route="/"
  total=$((total + 1))
  body="$(curl -s -o - -w '\n%{http_code}' --max-time 30 "$BASE$route")"
  code="$(echo "$body" | tail -n1)"
  if [ "$code" -ge 400 ] || echo "$body" | grep -qiE 'Internal Server Error|worker threw exception|Error 1101'; then
    echo "FAIL $code $route"
    fail=$((fail + 1))
  else
    echo "ok   $code $route"
  fi
done < <(find . -name page.tsx | sed 's#^\./##' | sort)

check_redirect() {
  local loc
  loc="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE$1")"
  if [[ "$loc" == 30?" $BASE$2" ]]; then echo "ok   redirect $1 -> $2"; else echo "FAIL redirect $1 ($loc)"; fail=$((fail + 1)); fi
}
check_redirect /dashboard/patient /account
check_redirect /dashboard/patient/appointments /account/appointments
check_redirect /dashboard/patient/appointments/abc /account/appointments/abc
check_redirect /dashboard/patient/billing /account/billing
check_redirect /dashboard/patient/waitlist /account/appointments
check_redirect /dashboard/patient/consultation/tok123 /consultation/tok123

echo "routes=$total failures=$fail"
[ "$fail" -eq 0 ]

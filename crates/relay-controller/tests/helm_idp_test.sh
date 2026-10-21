#!/usr/bin/env bash
# AC 21: Helm template test — tenant chart renders IdP env vars on relay container.
#
# This test runs `helm template` with idp values and asserts the rendered
# relay-ctrl Deployment contains the IDP_ISSUER, IDP_AUDIENCE, and
# IDP_CERTIFICATE_AUTHORITY environment variables.
#
# Must FAIL because the tenant chart does not yet accept an idp block or
# render the env vars.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly REPO_ROOT
source "$REPO_ROOT/lib/shell.sh"
CHART_DIR="$REPO_ROOT/charts/sycophant-tenant"
readonly CHART_DIR
FAILURES=0

rendered=$(helm template test-release "$CHART_DIR" \
  --set idp.issuer=https://dex.example.com \
  --set idp.audience=syco-client \
  --set "idp.certificateAuthority=test-ca-bundle" 2>&1) || {
  echo "FAIL: helm template exited non-zero (chart likely rejects unknown idp values)"
  exit 1
}
readonly rendered

# Check for IDP_ISSUER env var
if echo "$rendered" | grep -q 'IDP_ISSUER'; then
  echo "PASS: IDP_ISSUER found in rendered template"
else
  echo "FAIL: IDP_ISSUER not found in rendered relay-ctrl template"
  FAILURES=$((FAILURES + 1))
fi

# Check for IDP_AUDIENCE env var
if echo "$rendered" | grep -q 'IDP_AUDIENCE'; then
  echo "PASS: IDP_AUDIENCE found in rendered template"
else
  echo "FAIL: IDP_AUDIENCE not found in rendered relay-ctrl template"
  FAILURES=$((FAILURES + 1))
fi

# Check for IDP_CERTIFICATE_AUTHORITY env var
if echo "$rendered" | grep -q 'IDP_CERTIFICATE_AUTHORITY'; then
  echo "PASS: IDP_CERTIFICATE_AUTHORITY found in rendered template"
else
  echo "FAIL: IDP_CERTIFICATE_AUTHORITY not found in rendered relay-ctrl template"
  FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "RESULT: $FAILURES assertion(s) FAILED"
  exit 1
fi

echo ""
echo "RESULT: all assertions passed"
exit 0

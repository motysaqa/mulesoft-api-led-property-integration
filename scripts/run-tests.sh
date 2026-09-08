#!/usr/bin/env bash
#
# Run the MUnit suites for every Mule application.
#
# The Mule runtime and MUnit are distributed from MuleSoft's EE repository, which
# needs credentials. Rather than failing with a wall of Maven output, this script
# checks for them up front and says exactly what is missing.
#
#   ANYPOINT_USERNAME / ANYPOINT_PASSWORD   Anypoint Platform credentials
#   or a ~/.m2/settings.xml with the matching <server> entries (see docs/setup.md)
#
# Usage:
#   scripts/run-tests.sh                # all modules
#   scripts/run-tests.sh process-availability-pricing-api
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODULE="${1:-}"

if ! command -v mvn >/dev/null 2>&1; then
  cat >&2 <<'MSG'
Maven is not on PATH.

MUnit runs through the munit-maven-plugin, so Maven 3.8+ and a JDK 17 or 21 are
required. Install it, or open the project in Anypoint Studio and run the suites
from the MUnit view instead.
MSG
  exit 127
fi

if [[ -z "${ANYPOINT_USERNAME:-}" ]] && ! grep -q "anypoint-exchange-v3" "${HOME}/.m2/settings.xml" 2>/dev/null; then
  cat >&2 <<'MSG'
No Anypoint credentials found.

Neither ANYPOINT_USERNAME is set nor does ~/.m2/settings.xml contain a server
entry for anypoint-exchange-v3. Maven will not be able to resolve the Mule
runtime or the MUnit plugins, and the build will fail while downloading.

docs/setup.md, "Maven settings.xml", has the exact file to create.
Continuing anyway, in case a mirror or local repository already has them.
MSG
fi

MVN_ARGS=(-B -e clean test)
if [[ -n "$MODULE" ]]; then
  echo "Running MUnit for module: $MODULE"
  MVN_ARGS+=(-pl "$MODULE" -am)
else
  echo "Running MUnit for all modules"
fi

set +e
mvn "${MVN_ARGS[@]}"
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  cat >&2 <<'MSG'

The build failed. The three causes that account for almost all of these:
  1. Missing Anypoint credentials      -> 401 while downloading mule-*-ee artifacts
  2. Wrong JDK                         -> Mule 4.6 needs JDK 17 or 21, not 8 or 11
  3. A stale local repository          -> try: mvn -U clean test

docs/troubleshooting.md has the full list with the exact error text for each.
MSG
fi

exit $STATUS

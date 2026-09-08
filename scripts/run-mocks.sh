#!/usr/bin/env bash
#
# Start the two mock backends the Mule applications talk to.
#
#   property-backend    http://localhost:5081   (REST, JSON)
#   legacy-rates-soap   http://localhost:5082   (SOAP 1.1, document/literal)
#
# Both need the .NET 8 SDK. Logs go to .mocks/ and PIDs to .mocks/*.pid so
# `scripts/run-mocks.sh stop` can shut them down again.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RUN_DIR="$REPO_ROOT/.mocks"
mkdir -p "$RUN_DIR"

start_one() {
  local name="$1" project="$2" port="$3"
  local pid_file="$RUN_DIR/$name.pid"

  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "$name already running (pid $(cat "$pid_file"))"
    return
  fi

  echo "Starting $name on port $port"
  dotnet run --project "$project" -c Release > "$RUN_DIR/$name.log" 2>&1 &
  echo $! > "$pid_file"
}

wait_for() {
  local name="$1" url="$2"
  for _ in $(seq 1 40); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then
      echo "  $name is up"
      return 0
    fi
    sleep 0.5
  done
  echo "  $name did not become healthy - see $RUN_DIR/$name.log" >&2
  return 1
}

stop_all() {
  for pid_file in "$RUN_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "Stopping $(basename "$pid_file" .pid) (pid $pid)"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  done
}

case "${1:-start}" in
  start)
    if ! command -v dotnet >/dev/null 2>&1; then
      echo "The .NET 8 SDK is required to run the mocks (https://dotnet.microsoft.com/download)" >&2
      exit 127
    fi
    start_one property-backend  mocks/property-backend/PropertyBackend.Mock.csproj 5081
    start_one legacy-rates-soap mocks/legacy-rates-soap/LegacyRates.Mock.csproj    5082
    wait_for property-backend  http://localhost:5081/health
    wait_for legacy-rates-soap http://localhost:5082/health
    echo
    echo "Mocks are running. Next: start the four Mule apps (see README.md, 'How to run')."
    ;;
  stop)
    stop_all
    ;;
  *)
    echo "Usage: $0 [start|stop]" >&2
    exit 2
    ;;
esac

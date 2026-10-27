#!/usr/bin/env bash
# =============================================================================
# dashboard.sh — start the local "Sigstore Control Panel" (docs/14-dashboard.md).
#
#   scripts/dashboard.sh                 start on 127.0.0.1:9443 and open the browser
#   scripts/dashboard.sh --port 9500     choose another port (or DASHBOARD_PORT=9500)
#   scripts/dashboard.sh --no-open       only print the URL (headless / SSH sessions)
#
# Plain-Python (3.10+, standard library only) server, loopback only. A random
# access token is generated on every start and printed below; the URL ends in
# #token=<token> so the page can read it. Press Ctrl+C to stop.
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd python3
python3 - <<'PY' || die "Python 3.10 or newer is required"
import sys
sys.exit(0 if sys.version_info >= (3, 10) else 1)
PY
[[ -f "${KIT_ROOT}/dashboard/server.py" ]] || die "missing ${KIT_ROOT}/dashboard/server.py"

PORT="${DASHBOARD_PORT:-9443}"
args=()
while (( $# )); do
  case "$1" in
    --port)    PORT="${2:?--port needs a value}"; shift 2 ;;
    --no-open) args+=(--no-open); shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *)         die "unknown option: $1 (see --help)" ;;
  esac
done
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "invalid port: ${PORT}"

log "Starting the Sigstore Control Panel on 127.0.0.1:${PORT}"
# -I: isolated mode (ignores PYTHON* variables and user site-packages)
exec python3 -I "${KIT_ROOT}/dashboard/server.py" --host 127.0.0.1 --port "$PORT" ${args[@]+"${args[@]}"}

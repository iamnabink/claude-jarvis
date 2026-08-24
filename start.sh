#!/usr/bin/env bash
#
# Start JARVIS — backend (FastAPI/uvicorn) + frontend (Vite).
# Both run in the background; use ./stop.sh to shut them down.
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BACKEND_PORT=8340
FRONTEND_PORT=5173
RUN_DIR=".run"
LOG_DIR="logs"

bold=$'\033[1m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; dim=$'\033[2m'; off=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$green" "$off" "$1"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$off" "$1" >&2; }
note() { printf '  %s· %s%s\n' "$dim" "$1" "$off" >&2; }
die()  { printf '  %s✗%s %s\n' "$red" "$off" "$1" >&2; exit 1; }

port_pid() { lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }

printf '\n%sJ.A.R.V.I.S.%s\n\n' "$bold" "$off"

# --- Preflight ---------------------------------------------------------------
[ -d .venv ] || die "No .venv. Run: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
[ -x .venv/bin/python ] || die ".venv/bin/python missing or not executable. Recreate the venv."
[ -d frontend/node_modules ] || die "Frontend deps missing. Run: cd frontend && npm install"
[ -f .env ] || die "No .env. Run: cp .env.example .env  (then add your API keys)"

# Certs: the server auto-enables HTTPS when both exist, and the Vite proxy
# expects https://localhost:8340 — so a missing cert breaks the proxy.
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  warn "SSL certs missing — generating self-signed pair"
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 365 -nodes -subj '/CN=localhost' >/dev/null 2>&1 \
    || die "openssl failed to generate certs"
fi

for k in ANTHROPIC_API_KEY FISH_API_KEY; do
  v=$(grep -E "^${k}=" .env | head -1 | cut -d= -f2- | tr -d ' "'"'" )
  case "$v" in
    "")            warn "$k is empty in .env" ;;
    your-*-here)   warn "$k is still the placeholder value" ;;
  esac
done

mkdir -p "$RUN_DIR" "$LOG_DIR"

# --- Already running? --------------------------------------------------------
running=0
for p in "$BACKEND_PORT" "$FRONTEND_PORT"; do
  pid=$(port_pid "$p")
  [ -n "$pid" ] && { warn "Port $p already in use (pid $pid)"; running=1; }
done
[ "$running" = 1 ] && die "Already running. Use ./stop.sh first, or ./stop.sh && ./start.sh"

# Job control so each service gets its own process group — lets stop.sh kill
# npm *and* the vite child it spawns, instead of orphaning vite on the port.
set -m

# --- Backend -----------------------------------------------------------------
.venv/bin/python server.py >"$LOG_DIR/backend.log" 2>&1 &
backend_pid=$!
echo "$backend_pid" > "$RUN_DIR/backend.pid"

# --- Frontend ----------------------------------------------------------------
( cd frontend && exec npm run dev ) >"$LOG_DIR/frontend.log" 2>&1 &
frontend_pid=$!
echo "$frontend_pid" > "$RUN_DIR/frontend.pid"

set +m

# --- Wait for readiness ------------------------------------------------------
backend_up=0
for _ in $(seq 1 40); do
  if curl -sk --max-time 2 "https://localhost:$BACKEND_PORT/api/health" >/dev/null 2>&1; then
    backend_up=1; break
  fi
  kill -0 "$backend_pid" 2>/dev/null || break
  sleep 0.5
done

frontend_up=0
for _ in $(seq 1 40); do
  if curl -s --max-time 2 -o /dev/null "http://localhost:$FRONTEND_PORT"; then
    frontend_up=1; break
  fi
  kill -0 "$frontend_pid" 2>/dev/null || break
  sleep 0.5
done

# The shell job pid is normally the listener, but a service that re-execs (or a
# stale process squatting on the port) can diverge. Trust the port, not the job.
reconcile() {
  local svc=$1 port=$2 job_pid=$3
  local real_pid
  real_pid=$(port_pid "$port")
  if [ -n "$real_pid" ] && [ "$real_pid" != "$job_pid" ]; then
    note "$svc: pid $job_pid spawned $real_pid (the actual listener) — tracking both"
    printf '%s\n%s\n' "$job_pid" "$real_pid" > "$RUN_DIR/$svc.pid"
    echo "$real_pid"
  else
    echo "$job_pid"
  fi
}

[ "$backend_up" = 1 ]  && backend_pid=$(reconcile backend  "$BACKEND_PORT"  "$backend_pid")
[ "$frontend_up" = 1 ] && frontend_pid=$(reconcile frontend "$FRONTEND_PORT" "$frontend_pid")

if [ "$backend_up" = 1 ]; then ok "Backend   https://localhost:$BACKEND_PORT   ${dim}(pid $backend_pid)${off}"
else
  printf '  %s✗%s Backend failed to start — last lines of %s/backend.log:\n' "$red" "$off" "$LOG_DIR"
  tail -15 "$LOG_DIR/backend.log" | sed 's/^/      /'
fi

if [ "$frontend_up" = 1 ]; then ok "Frontend  http://localhost:$FRONTEND_PORT   ${dim}(pid $frontend_pid)${off}"
else
  printf '  %s✗%s Frontend failed to start — last lines of %s/frontend.log:\n' "$red" "$off" "$LOG_DIR"
  tail -15 "$LOG_DIR/frontend.log" | sed 's/^/      /'
fi

if [ "$backend_up" != 1 ] || [ "$frontend_up" != 1 ]; then
  printf '\n  Shutting down the half that did start.\n'
  ./stop.sh >/dev/null 2>&1
  exit 1
fi

printf '\n  Open %shttp://localhost:%s%s in Chrome, click to enable audio, and speak.\n' "$bold" "$FRONTEND_PORT" "$off"
printf '  Logs: %s/backend.log, %s/frontend.log   Stop: ./stop.sh\n\n' "$LOG_DIR" "$LOG_DIR"

#!/usr/bin/env bash
#
# Stop JARVIS — terminates the backend and frontend started by ./start.sh.
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BACKEND_PORT=8340
FRONTEND_PORT=5173
RUN_DIR=".run"

bold=$'\033[1m'; green=$'\033[32m'; yellow=$'\033[33m'; dim=$'\033[2m'; off=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$green" "$off" "$1"; }
info() { printf '  %s·%s %s\n' "$dim" "$off" "$1"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$off" "$1"; }

# TERM, then KILL if it ignores us. Negative pid targets the whole process
# group (npm + the vite child); falls back to the bare pid if that fails.
terminate() {
  local pid=$1
  kill -0 "$pid" 2>/dev/null || return 1
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  sleep 0.5
  return 0
}

printf '\n%sStopping JARVIS%s\n\n' "$bold" "$off"

stopped=0

# --- By recorded pid ---------------------------------------------------------
for svc in backend frontend; do
  pidfile="$RUN_DIR/$svc.pid"
  [ -f "$pidfile" ] || continue
  # May hold more than one pid: start.sh records both the job it launched and
  # the pid actually listening on the port when those differ.
  while read -r pid; do
    [ -n "$pid" ] || continue
    if terminate "$pid"; then
      ok "Stopped $svc ${dim}(pid $pid)${off}"
      stopped=1
    fi
  done < "$pidfile"
  rm -f "$pidfile"
done

# --- Sweep the ports ---------------------------------------------------------
# Catches anything the pidfiles missed: a server started by hand, a stale run,
# or a vite child that outlived its parent.
for entry in "backend:$BACKEND_PORT" "frontend:$FRONTEND_PORT"; do
  svc=${entry%%:*}; port=${entry##*:}
  for pid in $(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null); do
    if terminate "$pid"; then
      ok "Stopped stray $svc on port $port ${dim}(pid $pid)${off}"
      stopped=1
    fi
  done
done

# --- Verify ------------------------------------------------------------------
leftover=0
for port in "$BACKEND_PORT" "$FRONTEND_PORT"; do
  pid=$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1)
  [ -n "$pid" ] && { warn "Port $port still held by pid $pid — kill -9 $pid"; leftover=1; }
done

[ "$stopped" = 0 ] && [ "$leftover" = 0 ] && info "Nothing was running."

printf '\n'
[ "$leftover" = 1 ] && exit 1
exit 0

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_PYTHON="$ROOT_DIR/.venv/bin/python"
RUN_DIR="$ROOT_DIR/.run"
LOG_DIR="$RUN_DIR/logs"

ORBIT_PID_FILE="$RUN_DIR/orbit-core.pid"
MLX_PID_FILE="$RUN_DIR/mlx-server.pid"
ORBIT_LOG_FILE="$LOG_DIR/orbit-core.log"
MLX_LOG_FILE="$LOG_DIR/mlx-server.log"

ORBIT_PORT="${ORBIT_PORT:-8787}"
MLX_PORT="${MLX_PORT:-8080}"
MLX_MODEL="${MLX_MODEL:-mlx-community/Llama-3.2-3B-Instruct-4bit}"

MODE="${MODE:-battery}"
# "dev" keeps uvicorn --reload. "battery" runs without reload.
if [[ "${1:-}" == "--dev" ]]; then
  MODE="dev"
  shift
elif [[ "${1:-}" == "--battery" ]]; then
  MODE="battery"
  shift
fi

usage() {
  cat <<EOF
Usage:
  scripts/orbit-services.sh [--dev|--battery] <start|stop|restart|status>

Modes:
  --battery  Lower battery usage (default): runs ORBIT without --reload
  --dev      Developer mode: runs ORBIT with --reload

Env overrides:
  ORBIT_PORT, MLX_PORT, MLX_MODEL
EOF
}

require_python() {
  if [[ ! -x "$VENV_PYTHON" ]]; then
    echo "Missing venv python at: $VENV_PYTHON"
    echo "Create/repair your venv first."
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$RUN_DIR" "$LOG_DIR"
}

pid_alive() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

port_in_use() {
  local port="$1"
  lsof -n -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

start_orbit() {
  if pid_alive "$ORBIT_PID_FILE"; then
    echo "ORBIT core already running (pid $(cat "$ORBIT_PID_FILE"))."
    return 0
  fi
  if port_in_use "$ORBIT_PORT"; then
    echo "Port $ORBIT_PORT is already in use; skipping ORBIT core start."
    return 0
  fi

  local cmd=("$VENV_PYTHON" -m uvicorn app.main:app --port "$ORBIT_PORT")
  if [[ "$MODE" == "dev" ]]; then
    cmd+=(--reload)
  fi

  nohup "${cmd[@]}" >>"$ORBIT_LOG_FILE" 2>&1 &
  echo $! >"$ORBIT_PID_FILE"
  echo "Started ORBIT core (pid $(cat "$ORBIT_PID_FILE")) on port $ORBIT_PORT [mode=$MODE]."
}

start_mlx() {
  # The local tier is served by Ollama, which is already running as a system app and idles at
  # ~0% CPU. mlx_lm.server busy-spins at 100% of a core continuously even while serving nothing
  # (measured: 15:06 CPU time in 15:08 elapsed, zero requests) — a constant battery drain on a
  # laptop. Set ORBIT_USE_MLX=1 to bring it back.
  if [[ "${ORBIT_USE_MLX:-0}" != "1" ]]; then
    echo "Local LLM: Ollama (MLX skipped — set ORBIT_USE_MLX=1 to use it instead)."
    return 0
  fi
  if pid_alive "$MLX_PID_FILE"; then
    echo "MLX server already running (pid $(cat "$MLX_PID_FILE"))."
    return 0
  fi
  if port_in_use "$MLX_PORT"; then
    echo "Port $MLX_PORT is already in use; skipping MLX server start."
    return 0
  fi

  nohup "$VENV_PYTHON" -m mlx_lm.server \
    --model "$MLX_MODEL" \
    --port "$MLX_PORT" \
    >>"$MLX_LOG_FILE" 2>&1 &
  echo $! >"$MLX_PID_FILE"
  echo "Started MLX server (pid $(cat "$MLX_PID_FILE")) on port $MLX_PORT."
}

stop_pid_file() {
  local label="$1"
  local pid_file="$2"
  if ! [[ -f "$pid_file" ]]; then
    echo "$label not running."
    return 0
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    echo "Stopped $label (pid $pid)."
  else
    echo "$label pid file found, process already dead."
  fi
  rm -f "$pid_file"
}

status_line() {
  local label="$1"
  local pid_file="$2"
  local port="$3"
  if pid_alive "$pid_file"; then
    echo "$label: running (pid $(cat "$pid_file"), port $port)"
  else
    if port_in_use "$port"; then
      echo "$label: unknown pid file state, but port $port is in use"
    else
      echo "$label: stopped"
    fi
  fi
}

start_all() {
  require_python
  ensure_dirs
  cd "$ROOT_DIR"
  start_orbit
  start_mlx
  echo "Logs:"
  echo "  $ORBIT_LOG_FILE"
  echo "  $MLX_LOG_FILE"
}

stop_all() {
  stop_pid_file "ORBIT core" "$ORBIT_PID_FILE"
  stop_pid_file "MLX server" "$MLX_PID_FILE"
}

status_all() {
  status_line "ORBIT core" "$ORBIT_PID_FILE" "$ORBIT_PORT"
  status_line "MLX server" "$MLX_PID_FILE" "$MLX_PORT"
  echo "Mode: $MODE"
}

COMMAND="${1:-}"
case "$COMMAND" in
  start)
    start_all
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all
    start_all
    ;;
  status)
    status_all
    ;;
  *)
    usage
    exit 1
    ;;
esac

#!/usr/bin/env bash

# Google Colab deployment helper for ai-goofish-monitor.
# It installs runtime dependencies, builds the Vue frontend, installs
# Playwright Chromium, and starts the FastAPI server.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PORT="${SERVER_PORT:-8000}"
HOST="${SERVER_HOST:-0.0.0.0}"
LOG_FILE="${COLAB_LOG_FILE:-logs/colab-server.log}"
PID_FILE="${COLAB_PID_FILE:-logs/colab-server.pid}"
STARTUP_TIMEOUT_SECONDS="${COLAB_STARTUP_TIMEOUT_SECONDS:-30}"
FOREGROUND=false
SETUP_ONLY=false
SKIP_APT=false
SKIP_FRONTEND_BUILD=false
MIN_NODE_MAJOR=20

usage() {
    cat <<'EOF'
Usage:
  bash colab_deploy.sh [options]

Options:
  --foreground           Run uvicorn in the foreground.
  --setup-only           Install dependencies and build frontend, then exit.
  --skip-apt             Skip apt-get based system package installation.
  --skip-frontend-build  Skip npm install/build and existing dist copy.
  -h, --help             Show this help.

Colab notebook example:
  !git clone https://github.com/Usagi-org/ai-goofish-monitor
  %cd ai-goofish-monitor
  import os
  os.environ["OPENAI_API_KEY"] = "sk-..."
  os.environ["OPENAI_BASE_URL"] = "https://api.openai.com/v1/"
  os.environ["OPENAI_MODEL_NAME"] = "gpt-4.1-mini"
  !bash colab_deploy.sh

  from google.colab import output
  output.serve_kernel_port_as_window(8000)
EOF
}

log() {
    printf '[colab-deploy] %s\n' "$*"
}

warn() {
    printf '[colab-deploy][warn] %s\n' "$*" >&2
}

die() {
    printf '[colab-deploy][error] %s\n' "$*" >&2
    exit 1
}

wait_for_health() {
    local deadline
    local url
    deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
    url="http://127.0.0.1:${PORT}/health"

    while [ "$SECONDS" -lt "$deadline" ]; do
        if python3 - "$url" <<'PY'
import sys
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=2) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
        then
            return 0
        fi
        sleep 1
    done

    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --foreground)
            FOREGROUND=true
            ;;
        --setup-only)
            SETUP_ONLY=true
            ;;
        --skip-apt)
            SKIP_APT=true
            ;;
        --skip-frontend-build)
            SKIP_FRONTEND_BUILD=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required."
fi

if ! python3 - <<'PY'
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
then
    die "Python 3.10+ is required."
fi

mkdir -p data images jsonl logs prompts state

if [ ! -f config.json ]; then
    printf '{}\n' > config.json
    log "Created config.json with an empty object."
fi

export RUN_HEADLESS="${RUN_HEADLESS:-true}"
export LOGIN_IS_EDGE="${LOGIN_IS_EDGE:-false}"
export SERVER_PORT="$PORT"
export APP_DATABASE_FILE="${APP_DATABASE_FILE:-$ROOT_DIR/data/app.sqlite3}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$ROOT_DIR/.playwright}"

missing_ai=()
[ -n "${OPENAI_API_KEY:-}" ] || missing_ai+=("OPENAI_API_KEY")
[ -n "${OPENAI_BASE_URL:-}" ] || missing_ai+=("OPENAI_BASE_URL")
[ -n "${OPENAI_MODEL_NAME:-}" ] || missing_ai+=("OPENAI_MODEL_NAME")
if [ "${#missing_ai[@]}" -gt 0 ]; then
    warn "Missing AI environment variables: ${missing_ai[*]}"
    warn "The web server can start, but AI analysis will not work until they are set in the notebook environment."
fi

if [ "$SKIP_APT" = false ] && command -v apt-get >/dev/null 2>&1; then
    log "Installing system packages with apt-get."
    apt-get update
    apt-get install -y curl ca-certificates
    if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt "$MIN_NODE_MAJOR" ]; then
        log "Installing Node.js 20 from NodeSource."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    else
        log "Existing Node.js version is sufficient: $(node --version)"
    fi
else
    log "Skipping apt-get step."
fi

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    die "Node.js and npm are required. Re-run without --skip-apt or install Node.js in the Colab runtime."
fi

node_major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
if [ "$node_major" -lt "$MIN_NODE_MAJOR" ]; then
    die "Node.js 20+ is required for the frontend build. Current version: $(node --version 2>/dev/null || echo unknown)"
fi

log "Installing Python dependencies."
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

log "Installing Playwright Chromium."
python3 -m playwright install chromium
if [ "$SKIP_APT" = false ]; then
    python3 -m playwright install-deps chromium || warn "playwright install-deps failed; continuing because Colab often already has compatible libraries."
fi

if [ "$SKIP_FRONTEND_BUILD" = false ]; then
    log "Installing frontend dependencies."
    npm --prefix web-ui ci

    log "Building frontend."
    npm --prefix web-ui run build

    log "Copying frontend build to root dist/."
    mkdir -p dist
    cp -R web-ui/dist/. dist/
else
    log "Skipping frontend build."
fi

if [ "$SETUP_ONLY" = true ]; then
    log "Setup complete."
    exit 0
fi

start_cmd=(python3 -m uvicorn src.app:app --host "$HOST" --port "$PORT")

if [ "$FOREGROUND" = true ]; then
    log "Starting server in foreground at http://127.0.0.1:$PORT"
    exec "${start_cmd[@]}"
fi

if [ -f "$PID_FILE" ]; then
    old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1; then
        warn "Server already appears to be running with PID $old_pid."
        warn "Stop it manually if you need to restart: kill $old_pid"
        exit 0
    fi
fi

log "Starting server in background at http://127.0.0.1:$PORT"
nohup "${start_cmd[@]}" >"$LOG_FILE" 2>&1 &
server_pid="$!"
printf '%s\n' "$server_pid" > "$PID_FILE"

log "Server PID: $server_pid"
log "Log file: $LOG_FILE"
if wait_for_health; then
    log "Health check passed."
else
    warn "Health check did not pass within ${STARTUP_TIMEOUT_SECONDS}s."
    warn "Recent server log:"
    tail -n 80 "$LOG_FILE" >&2 || true
fi
log "In Colab, expose the UI with:"
printf 'from google.colab import output\noutput.serve_kernel_port_as_window(%s)\n' "$PORT"

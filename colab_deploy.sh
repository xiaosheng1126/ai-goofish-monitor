#!/usr/bin/env bash

# Google Colab deployment helper for ai-goofish-monitor.
# It installs runtime dependencies, builds the Vue frontend, installs
# Playwright Chromium, and starts the FastAPI server in an isolated uv venv.

set -Eeuo pipefail

PORT="${SERVER_PORT:-8000}"
HOST="${SERVER_HOST:-0.0.0.0}"
STARTUP_TIMEOUT_SECONDS="${COLAB_STARTUP_TIMEOUT_SECONDS:-30}"
REPO_URL="${COLAB_REPO_URL:-https://github.com/xiaosheng1126/ai-goofish-monitor.git}"
PROJECT_DIR="${COLAB_PROJECT_DIR:-/content/ai-goofish-monitor}"
FOREGROUND=false
SETUP_ONLY=false
SKIP_APT=false
SKIP_FRONTEND_BUILD=false
SKIP_OPEN_WINDOW=false
MIN_NODE_MAJOR=20
PYTHON_VERSION="${COLAB_PYTHON_VERSION:-3.11}"
VENV_DIR="${COLAB_VENV_DIR:-.venv}"

usage() {
    cat <<'EOF'
Usage:
  bash colab_deploy.sh [options]
  curl -fsSL https://raw.githubusercontent.com/xiaosheng1126/ai-goofish-monitor/master/colab_deploy.sh | bash

Options:
  --foreground           Run uvicorn in the foreground.
  --setup-only           Install dependencies and build frontend, then exit.
  --skip-apt             Skip apt-get based system package installation.
  --skip-frontend-build  Skip npm install/build and existing dist copy.
  --skip-open-window     Skip opening the Colab proxied Web UI.
  -h, --help             Show this help.

Colab notebook example:
  !OPENAI_API_KEY="sk-..." OPENAI_BASE_URL="https://api.openai.com/v1/" OPENAI_MODEL_NAME="gpt-4.1-mini" \
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/xiaosheng1126/ai-goofish-monitor/master/colab_deploy.sh)"
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

is_project_dir() {
    [ -f "requirements.txt" ] && [ -f "web-ui/package.json" ] && [ -f "src/app.py" ]
}

bootstrap_project_dir() {
    if is_project_dir; then
        ROOT_DIR="$(pwd)"
        return
    fi

    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$script_dir/requirements.txt" ] && [ -f "$script_dir/web-ui/package.json" ] && [ -f "$script_dir/src/app.py" ]; then
            ROOT_DIR="$script_dir"
            cd "$ROOT_DIR"
            return
        fi
    fi

    if ! command -v git >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            log "Installing git for repository bootstrap."
            apt-get update
            apt-get install -y git ca-certificates
        else
            die "git is required to clone the project."
        fi
    fi

    if [ ! -d "$PROJECT_DIR/.git" ]; then
        log "Cloning project into $PROJECT_DIR"
        git clone "$REPO_URL" "$PROJECT_DIR"
    else
        log "Using existing project directory: $PROJECT_DIR"
    fi

    cd "$PROJECT_DIR"
    if ! is_project_dir; then
        die "$PROJECT_DIR is not a valid ai-goofish-monitor checkout."
    fi
    ROOT_DIR="$(pwd)"
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

open_colab_window() {
    if [ "$SKIP_OPEN_WINDOW" = true ]; then
        return
    fi

    python3 - "$PORT" <<'PY'
import sys

port = int(sys.argv[1])
try:
    from google.colab import output
except Exception:
    print("Not running inside Google Colab. Open http://127.0.0.1:%s manually." % port)
else:
    output.serve_kernel_port_as_window(port)
PY
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
        --skip-open-window)
            SKIP_OPEN_WINDOW=true
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

bootstrap_project_dir

LOG_FILE="${COLAB_LOG_FILE:-logs/colab-server.log}"
PID_FILE="${COLAB_PID_FILE:-logs/colab-server.pid}"

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

log "Installing uv and creating isolated Python ${PYTHON_VERSION} environment."
python3 -m pip install --upgrade pip uv
uv python install "$PYTHON_VERSION"
uv venv --python "$PYTHON_VERSION" "$VENV_DIR"
PYTHON_BIN="$ROOT_DIR/$VENV_DIR/bin/python"

log "Installing Python dependencies into $VENV_DIR."
uv pip install --python "$PYTHON_BIN" -r requirements.txt

log "Installing Playwright Chromium."
"$PYTHON_BIN" -m playwright install chromium
if [ "$SKIP_APT" = false ]; then
    "$PYTHON_BIN" -m playwright install-deps chromium || warn "playwright install-deps failed; continuing because Colab often already has compatible libraries."
fi

if [ "$SKIP_FRONTEND_BUILD" = false ]; then
    log "Installing frontend dependencies."
    npm --prefix web-ui ci

    log "Building frontend."
    npm --prefix web-ui run build

    if [ ! -d "dist" ]; then
        die "Frontend build failed: root dist/ was not generated."
    fi
    log "Frontend build output is available at root dist/."
else
    log "Skipping frontend build."
fi

if [ "$SETUP_ONLY" = true ]; then
    log "Setup complete."
    exit 0
fi

start_cmd=("$PYTHON_BIN" -m uvicorn src.app:app --host "$HOST" --port "$PORT")

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
log "Opening Colab proxied Web UI."
open_colab_window
log "If the window did not open, run this in a Colab Python cell:"
printf 'from google.colab import output\noutput.serve_kernel_port_as_window(%s)\n' "$PORT"

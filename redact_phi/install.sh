#!/usr/bin/env bash
set -euo pipefail

VENV_DIR=".venv"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
if ! command -v ccache >/dev/null 2>&1; then
	echo "warning: ccache not found; Paddle may compile slower on first run." >&2
	echo "install it with: sudo apt-get install ccache (Debian/Ubuntu) or brew install ccache (macOS)" >&2
fi

if [ ! -f "$VENV_DIR/bin/activate" ]; then
	rm -rf "$VENV_DIR"
	python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

"$VENV_DIR/bin/pip" install -r requirements.txt
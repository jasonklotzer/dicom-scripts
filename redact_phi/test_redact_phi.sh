#!/usr/bin/env bash
set -euo pipefail

# Simple test runner for redact_phi.py using the provided test.dcm file.

usage() {
  cat <<EOF
Usage: $0 [-o <out-dir>]

Options:
  -o, --out-dir   Optional. Output directory for generated PNGs (default: ./out next to this script).
  -h, --help      Show this help.

Examples:
  $0
  $0 --out-dir /tmp/redact_phi_outputs
EOF
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
OUT_DIR="$SCRIPT_DIR/out"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"

# Ensure venv and dependencies are present
pushd "$SCRIPT_DIR" >/dev/null
./install.sh
# shellcheck disable=SC1091
source .venv/bin/activate

TEST_FILES_DIR="$SCRIPT_DIR/test/files"

if [ ! -d "$TEST_FILES_DIR" ]; then
    echo "Test files directory not found: $TEST_FILES_DIR"
    exit 1
fi

for input_file in "$TEST_FILES_DIR"/*.dcm; do
    [ -e "$input_file" ] || continue
    
    filename=$(basename "$input_file" .dcm)
    echo "Processing $filename..."

    python redact_phi.py \
      --input "$input_file" \
      --out-pre "$OUT_DIR/${filename}_pre.png" \
      --out-post "$OUT_DIR/${filename}_post.png" \
      --out-text "$OUT_DIR/${filename}_text.txt"
done

popd >/dev/null

echo "Outputs written to: $OUT_DIR"
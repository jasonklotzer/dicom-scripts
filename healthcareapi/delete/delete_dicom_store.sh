#!/usr/bin/env bash
set -euo pipefail

# Deletion script for DICOM stores using Google Cloud Healthcare API v1

# Default values
VERBOSE=false

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

reqCmdExists() {
  command -v $1 >/dev/null 2>&1 || { fail "Command '$1' is required, but not installed."; }
}

usage() {
  cat << EOF
Usage: $0 -s <storePath> [options]

Required arguments:
  -s <storePath>         Full path of the DICOM store to be deleted.
                         Format: projects/PROJECT_ID/locations/LOCATION/datasets/DATASET_ID/dicomStores/STORE_ID

Options:
  -v                     Verbose output (show API responses)
  -h                     Show this help message

Examples:
  # Delete a DICOM store
  $0 -s projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/store-to-delete

  # Delete a DICOM store with verbose output
  $0 -s projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/store-to-delete -v
EOF
  exit 0
}

# Parse command line arguments

# Support --help and --verbose before getopts
for arg in "$@"; do
  case "$arg" in
    --help)
      usage
      ;;
    --verbose)
      VERBOSE=true
      ;;
  esac
done

while getopts "s:vh" opt; do
  case $opt in
    s) STORE_PATH="$OPTARG" ;;
    v) VERBOSE=true ;;
    h) usage ;;
    \?) fail "Invalid option: -$OPTARG" ;;
  esac
done

# Validate required commands
REQ_COMMANDS="gcloud curl jq"
for COMMAND in $REQ_COMMANDS; do
  reqCmdExists ${COMMAND}
done

# Validate required arguments
[ -z "${STORE_PATH:-}" ] && fail "DICOM store path is required (-s)"

# Validate store path format
if [[ ! "$STORE_PATH" =~ ^projects/[^/]+/locations/[^/]+/datasets/[^/]+/dicomStores/[^/]+$ ]]; then
  fail "Invalid DICOM store path format. Expected: projects/PROJECT/locations/LOCATION/datasets/DATASET/dicomStores/STORE"
fi

echo "=== DICOM Store Deletion ==="
echo "Store Path: ${STORE_PATH}"
echo "============================"
echo ""
read -p "Are you sure you want to permanently delete this DICOM store? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    echo "Deletion cancelled."
    exit 1
fi
echo ""


# Get authentication token
if [ "$VERBOSE" = true ]; then
  echo "Getting authentication token..."
fi
BEARER_TOKEN=$(gcloud auth application-default print-access-token)

# Submit the deletion request
echo "Submitting deletion request..."
API_URL="https://healthcare.googleapis.com/v1/${STORE_PATH}"

RESPONSE=$(curl -X DELETE \
  --silent \
  --fail \
  -H "Authorization: Bearer ${BEARER_TOKEN}" \
  -H "Content-Type: application/json" \
  "$API_URL")

if [ "$VERBOSE" = true ]; then
  echo "API Response:"
  echo "$RESPONSE" | jq .
  echo ""
fi

echo "DICOM store deletion request submitted successfully."
echo "If the store existed, it has been deleted."
echo ""

#!/bin/bash

set -e #-x

REQ_COMMANDS="gcloud curl"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

show_help() {
  cat << EOF
Usage: $0 [OPTIONS] <dicomStorePath> <dcmFilePath>

Insert a single DICOM file into a Google Cloud Healthcare API DICOM store.

ARGUMENTS:
  <dicomStorePath>    The path to the DICOM store in the format:
                      projects/PROJECT_ID/locations/LOCATION/datasets/DATASET_ID/dicomStores/DICOM_STORE_ID
  <dcmFilePath>       Path to the DICOM file (.dcm) to upload

OPTIONS:
  -h, --help          Show this help message and exit

EXAMPLES:
  $0 projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store file.dcm
  $0 --help

REQUIREMENTS:
  - gcloud CLI tool must be installed and authenticated
  - curl command must be available
  - Google Cloud Healthcare API must be enabled in your project

NOTES:
  - Uses PUT method with v1beta1 API endpoint
  - Automatically handles 429 (rate limit) errors with retries
  - Requires valid authentication via gcloud auth application-default login
EOF
}

reqCmdExists() {
  command -v $1 >/dev/null 2>&1 || { fail "Command '$1' is required, but not installed."; }
}

for COMMAND in $REQ_COMMANDS; do reqCmdExists ${COMMAND}; done

# Check for help flag
case "${1:-}" in
  -h|--help)
    show_help
    exit 0
    ;;
esac

[ $# -ne 2 ] && { fail "Usage: $0 <dicomStorePath> <dcmFilePath> (use --help for more information)"; }

BEARER_TOKEN=$(gcloud auth application-default print-access-token)
$SCRIPT_DIR/put.sh "$BEARER_TOKEN" "$1" "$2"

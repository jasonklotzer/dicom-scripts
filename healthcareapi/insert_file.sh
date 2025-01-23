#!/bin/bash

set -e #-x

REQ_COMMANDS="gcloud curl"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

reqCmdExists() {
  command -v $1 >/dev/null 2>&1 || { fail "Command '$1' is required, but not installed."; }
}

for COMMAND in $REQ_COMMANDS; do reqCmdExists ${COMMAND}; done
[ $# -ne 2 ] && { fail "Usage: $0 <dicomStorePath> <dcmFilePath>"; }

HCAPI_HOST=https://healthcare.googleapis.com/v1
DICOMWEB_HOST="${HCAPI_HOST}/$1/dicomWeb/studies"
BEARER_TOKEN=$(gcloud auth application-default print-access-token)
$SCRIPT_DIR/post.sh "$BEARER_TOKEN" $DICOMWEB_HOST "$2"

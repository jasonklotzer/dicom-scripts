#!/bin/bash

set -e #-x

[ $# -lt 1 ] && { echo "Usage: $0 <instancePath>"; exit 1; }

# TODO: Check for dcm2json, jq, curl

HCAPI_HOST=https://healthcare.googleapis.com/v1
DICOMWEB_HOST=${HCAPI_HOST}/projects/jklotzer-sandbox/locations/us/datasets/sandbox2/dicomStores/datastore1/dicomWeb/studies
BEARER_TOKEN=$(gcloud auth application-default print-access-token)
./insert.sh "$BEARER_TOKEN" $DICOMWEB_HOST "$1"

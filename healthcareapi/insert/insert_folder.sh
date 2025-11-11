#!/bin/bash

set -e #-x

REQ_COMMANDS="gcloud jq curl"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

show_help() {
  cat << EOF
Usage: $0 [OPTIONS] <dicomStorePath> <studyFolder>

Insert all DICOM files from a folder into a Google Cloud Healthcare API DICOM store.

ARGUMENTS:
  <dicomStorePath>    The path to the DICOM store in the format:
                      projects/PROJECT_ID/locations/LOCATION/datasets/DATASET_ID/dicomStores/DICOM_STORE_ID
  <studyFolder>       Path to the folder containing DICOM files (.dcm) to upload

OPTIONS:
  -s, --single-study  Process only a single study (uses first DICOM file's StudyInstanceUID)
  -d, --skip-delete   Skip deletion of existing studies before inserting new ones
  -p, --max-procs <N> Maximum number of parallel processes (default: 50)
  -h, --help          Show this help message and exit

EXAMPLES:
  # Basic usage - insert all studies from folder
  $0 projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store /path/to/dicom/folder

  # Insert single study only, skip deletion, use 20 parallel processes
  $0 -s -d -p 20 projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store /path/to/dicom/folder

  # Show help
  $0 --help

REQUIREMENTS:
  - gcloud CLI tool must be installed and authenticated
  - jq command must be available for JSON processing
  - curl command must be available
  - dcm2bq tool must be available (for StudyInstanceUID extraction, unless --skip-delete is used)
  - Google Cloud Healthcare API must be enabled in your project

BEHAVIOR:
  1. By default, extracts all unique StudyInstanceUIDs from DICOM files in the folder
  2. Deletes existing studies with matching UIDs (unless --skip-delete is specified)
  3. Waits for deletion operations to complete
  4. Ingests all DICOM files using POST method with v1 API endpoint
  5. Outputs response statistics and HTTP codes

NOTES:
  - Uses POST method with v1 API endpoint
  - Automatically handles 429 (rate limit) errors with retries
  - Processes files in parallel for better performance
  - Creates errcodes.json file with response details
  - Requires valid authentication via gcloud auth application-default login
EOF
}

reqCmdExists() {
  command -v $1 >/dev/null 2>&1 || { fail "Command '$1' is required, but not installed."; }
}

waitDeleteStudy() {
  local study_uid=$1
  # Try to delete the study and if it exists wait for the LRO to complete
  local delete_op=$(curl --silent --fail -X DELETE -H "Authorization: Bearer $BEARER_TOKEN" $DICOMWEB_HOST/$study_uid | jq -r '.name')
  if [ ! -z "$delete_op" ]; then
    echo "Waiting for delete LRO $delete_op..."
    while true; do
      local delete_op_status=$(curl --silent --fail -X GET -H "Authorization: Bearer $BEARER_TOKEN" $HCAPI_HOST/$delete_op | jq -r '.done')
      [ "$delete_op_status" == "true" ] && { break; }
      sleep 5
    done
  fi
}

for COMMAND in $REQ_COMMANDS; do reqCmdExists $COMMAND; done
[ $# -lt 2 ] && { fail "Usage: $0 [-s|--single-study] [-d|--skip-delete] [-p|--max-procs <numberOfThreads>] <dicomStorePath> <studyFolder> (use --help for more information)"; }

while :; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    -s|--single-study) SINGLE_STUDY=1
    ;;
    -d|--skip-delete) SKIP_DELETE=1
    ;;
    -p|--max-procs) shift; MAX_PROCS=$1
    ;;
    *) DICOMSTORE_PATH=$1; shift; FOLDER=$1; break;
  esac
  shift
done

HCAPI_HOST=https://healthcare.googleapis.com/v1
DICOMWEB_HOST="${HCAPI_HOST}/${DICOMSTORE_PATH}/dicomWeb/studies"
BEARER_TOKEN="$(gcloud auth application-default print-access-token)"
MAX_PROCS="${MAX_PROCS:-50}"
ERR_CODES=errcodes.json

echo "Using destination DICOMweb store $DICOMWEB_HOST"

if [ -z "$SKIP_DELETE" ]; then
  reqCmdExists "dcm2bq"
  if [ -z "$SINGLE_STUDY" ]; then
    # Find all the studyUIDs
    echo "Finding all the studyUIDs in the folder..."
    study_uids=( $(find $FOLDER -name "*.dcm" | xargs --max-procs $MAX_PROCS -I @ sh -c 'dcm2bq dump "@" | jq -r ".StudyInstanceUID"' | sort -u) )
    for study_uid in "${study_uids[@]}"; do
      echo "Deleting studyUID $study_uid..."
      waitDeleteStudy $study_uid
    done
  else
    study_uid=$(find $FOLDER -name "*.dcm" | head -1 | xargs -I @ sh -c 'dcm2bq dump "@" | jq -r ".StudyInstanceUID"')
    echo "Deleting studyUID $study_uid..."
    waitDeleteStudy $study_uid
  fi
fi

# Ingest all the studies in the folder
echo "Ingesting studyUID(s) with $MAX_PROCS processors..."
INGEST_START_MS="$(date +%s%3N)"
find $FOLDER -type f | xargs --max-procs $MAX_PROCS -I @ $SCRIPT_DIR/post.sh "$BEARER_TOKEN" $DICOMWEB_HOST "@" > $ERR_CODES
echo "Received `wc -l $ERR_CODES | awk '{print $1}'` responses in $[ $(date +%s%3N) - $INGEST_START_MS ]ms"
echo "HTTP response codes:"
jq --slurp '.[].code' $ERR_CODES | sort -u


#!/bin/bash

set -e #-x

[ $# -lt 1 ] && { echo "Usage: $0 [--single-study] <studyFolder>"; exit 1; }
while :; do
    case $1 in
        -s|--single-study) SINGLE_STUDY=1
        ;;
        *) FOLDER=$1; break;
    esac
    shift
done

# TODO: Check for dcm2json, jq, curl

HCAPI_HOST=https://healthcare.googleapis.com/v1
DICOMWEB_HOST=${HCAPI_HOST}/projects/jklotzer-sandbox/locations/us/datasets/sandbox2/dicomStores/datastore1/dicomWeb/studies
BEARER_TOKEN=$(gcloud auth application-default print-access-token)
MAX_PROCS=50

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

if [ -z "$SINGLE_STUDY" ]; then
  # Find all the studyUIDs
  echo "Finding all the studyUIDs in the folder..."
  study_uids=( $(find $FOLDER -name "*.dcm" | xargs --max-procs $MAX_PROCS -I @ sh -c 'dcm2json -B "@" | jq -r ".\"0020000D\".Value[0]"' | sort -u) )
  for study_uid in $study_uids; do
    echo "Deleting studyUID $study_uid..."
    waitDeleteStudy $study_uid
  done
else
  study_uid=$(find $FOLDER -name "*.dcm" | head -1 | xargs -I @ sh -c 'dcm2json -B "@" | jq -r ".\"0020000D\".Value[0]"')
  echo "Deleting studyUID $study_uid..."
  waitDeleteStudy $study_uid
fi

# Ingest all the studies in the folder
echo "Ingesting studyUID(s)..."
INGEST_START_MS="$(date +%s%3N)"
find $FOLDER -type f | xargs --max-procs $MAX_PROCS -I @ ./insert.sh "$BEARER_TOKEN" $DICOMWEB_HOST "@" > errcodes.txt
echo "Received `wc -l errcodes.txt | awk '{print $1}'` responses in $[ $(date +%s%3N) - $INGEST_START_MS ]ms"
echo "HTTP response codes:"
sort -u errcodes.txt

#!/bin/bash

set -e -x

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
  local STUDY_UID=$1
  # Try to delete the study and if it exists wait for the LRO to complete
  local OPERATION=$(curl --silent --fail -X DELETE -H "Authorization: Bearer $BEARER_TOKEN" $DICOMWEB_HOST/$STUDY_UID | jq -r '.name')
  if [ ! -z "$OPERATION" ]; then
    printf "Waiting for delete LRO ${OPERATION}...\n"
    while true; do
      local OPERATION_COMPLETE=$(curl --silent --fail -X GET -H "Authorization: Bearer $BEARER_TOKEN" $HCAPI_HOST/$OPERATION | jq -r '.done')
      [ "$OPERATION_COMPLETE" == "true" ] && { break; }
      sleep 5
    done
  fi
}

if [ -z "$SINGLE_STUDY" ]; then
  # Find all the studyUIDs
  printf "Finding all the studyUIDs in the folder...\n"
  STUDY_UIDS=( $(find $FOLDER -name "*.dcm" | xargs --max-procs $MAX_PROCS -I @ sh -c 'dcm2json -B "@" | jq -r ".\"0020000D\".Value[0]"' | sort -u) )
  for STUDY_UID in $STUDY_UIDS; do
    printf "Deleting studyUID $STUDY_UID...\n"
    waitDeleteStudy $STUDY_UID
  done
else
  STUDY_UID=$(find $FOLDER -name "*.dcm" | head -1 | xargs -I @ sh -c 'dcm2json -B "@" | jq -r ".\"0020000D\".Value[0]"')
  waitDeleteStudy $STUDY_UID
fi

# Ingest all the studies in the folder
printf "Ingesting studyUIDs ${STUDY_UIDS}...\n"
time find $FOLDER -type f | xargs --max-procs $MAX_PROCS -I @ ./insert.sh "$BEARER_TOKEN" $DICOMWEB_HOST "@" > errcodes.txt 2> output.txt

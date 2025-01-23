#!/bin/bash

[ $# -lt 3 ] && { echo "Usage: $0 <bearerToken> <dicomWebHost> <dcmFilePath>"; exit 1; }

BEARER_TOKEN=$1
DICOMWEB_HOST=$2
FILE_PATH=$3
START_MS="$(date +%s%3N)"

# Try to insert the study, and then retry if it's a 429
while true; do
  HTTP_RESULT=$(curl -X POST --silent --output /dev/null --write-out "%{http_code}" --max-time 60 -H "Content-Type: application/dicom" -H "Authorization: Bearer ${BEARER_TOKEN}" ${DICOMWEB_HOST} -T "${FILE_PATH}")
  [[ "$HTTP_RESULT" == "200" || "$HTTP_RESULT" != "429" ]] && { break; }
  #sleep 1 # TODO: Find a better interval
done
echo "{\"code\":${HTTP_RESULT},\"filePath\":\"$FILE_PATH\",\"timeMs\":$[ $(date +%s%3N) - $START_MS ]}"

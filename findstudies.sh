#!/bin/bash

set -e #-x

REQ_COMMANDS="findscu dcm2json"

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

reqCmdExists() {
  command -v $1 >/dev/null 2>&1 || { fail "Command '$1' is required, but not installed."; }
}

for COMMAND in $REQ_COMMANDS; do reqCmdExists ${COMMAND}; done

[ $# -lt 3 ] && { fail "Usage: $0 <calledAE> <ip/host> <port> [<startDate>]"; }

PACS_HOST="$1 $2 $3" # <ae> <ip/host> <port>

START_DATE=$4
START_DATE=${START_DATE:-20000101}
END_DATE=$(date +"%Y%m%d")
TMP_DIR=./resp
RESP_FILE=$TMP_DIR/responses.json

mkdir -p $TMP_DIR
truncate -s 0 $RESP_FILE # clear file

echo "Finding studies from $START_DATE to $END_DATE"

CURR_DATE=$START_DATE
while : ; do
  echo $CURR_DATE
  CURR_DATE=$(date +"%Y%m%d" -ud "$CURR_DATE UTC + 1 day")
  findscu -S -k QueryRetrieveLevel=STUDY -k StudyDate="$CURR_DATE" -k NumberOfStudyRelatedInstances -aet SAFEBRIDGE -aec $PACS_HOST -od $TMP_DIR -X
  find $TMP_DIR -name "*.dcm"  | xargs -I % dcm2json -fc % >> $RESP_FILE
  find $TMP_DIR -name "*.dcm" -delete
  [ "$CURR_DATE" -le "$END_DATE" ] || break
done

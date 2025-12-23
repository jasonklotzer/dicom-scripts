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
  findscu -S -k QueryRetrieveLevel=STUDY -k StudyDate="$CURR_DATE" -k NumberOfStudyRelatedInstances -aet SAFEBRIDGE -aec $PACS_HOST -od $TMP_DIR -X
  find $TMP_DIR -name "*.dcm"  | xargs -I % dcm2json -fc % >> $RESP_FILE
  find $TMP_DIR -name "*.dcm" -delete
  CURR_DATE=$(date +"%Y%m%d" -ud "$CURR_DATE UTC + 1 day")
  [ "$CURR_DATE" -le "$END_DATE" ] || break
done
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

[ $# -lt 3 ] && { fail "Usage: $0 <calledAE> <ip/host> <port> [<startDate>] [<endDate>]"; }

PACS_HOST="$1 $2 $3" # <ae> <ip/host> <port>

START_DATE=$4
START_DATE=${START_DATE:-20000101}
END_DATE=$5
END_DATE=${END_DATE:-$(date +"%Y%m%d")}

# Validate date format (YYYYMMDD)
validateDateFormat() {
  local date=$1
  local name=$2
  if ! [[ $date =~ ^[0-9]{8}$ ]]; then
    fail "$name must be in DICOM DA format (YYYYMMDD), got: $date"
  fi
  # Verify it's a valid date
  if ! date -d "${date:0:4}-${date:4:2}-${date:6:2}" >/dev/null 2>&1; then
    fail "$name is not a valid date: $date"
  fi
}

validateDateFormat "$START_DATE" "START_DATE"
validateDateFormat "$END_DATE" "END_DATE"

TMP_DIR=./resp
RESP_FILE=$TMP_DIR/responses.json

mkdir -p $TMP_DIR
truncate -s 0 $RESP_FILE # clear file

echo "Finding studies from $START_DATE to $END_DATE"

# Run a query for a given date and optional StudyTime range.
# Args: date [startTime] [endTime] [label]
# Outputs: echoes the count of results found
query_block() {
  local date="$1"
  local start_time="$2"
  local end_time="$3"
  local label="$4"

  if [ -n "$start_time" ] && [ -n "$end_time" ]; then
    printf >&2 "  Querying %s %s (StudyTime %s-%s)\n" "$date" "$label" "$start_time" "$end_time"
    findscu -S -k QueryRetrieveLevel=STUDY -k StudyDate="$date" -k StudyTime="$start_time-$end_time" -k NumberOfStudyRelatedInstances -aet SAFEBRIDGE -aec $PACS_HOST -od $TMP_DIR -X > /dev/null
  else
    printf >&2 "  Querying %s (full day)\n" "$date"
    findscu -S -k QueryRetrieveLevel=STUDY -k StudyDate="$date" -k NumberOfStudyRelatedInstances -aet SAFEBRIDGE -aec $PACS_HOST -od $TMP_DIR -X > /dev/null
  fi

  local count
  count=$(find $TMP_DIR -name "*.dcm" | wc -l | tr -d '[:space:]')
  if [ "$count" -gt 0 ]; then
    find $TMP_DIR -name "*.dcm" | xargs -I % dcm2json -fc % >> $RESP_FILE
  fi
  find $TMP_DIR -name "*.dcm" -delete
  echo "$count"
}

CURR_DATE=$START_DATE
while : ; do
  echo "Processing date: $CURR_DATE"

  # Query full day first
  DAY_RESULT_COUNT=$(query_block "$CURR_DATE" "" "" "day")

  if [ "$DAY_RESULT_COUNT" -eq 100 ]; then
    echo "  WARNING: Hit 100 result limit for day, re-querying in 1-hour blocks"
    DAY_TOTAL=0
    for HOUR in {0..23}; do
      HOUR_STR=$(printf "%02d" $HOUR)
      HOUR_START="${HOUR_STR}0000"
      HOUR_END="${HOUR_STR}5959"

      HOUR_RESULT_COUNT=$(query_block "$CURR_DATE" "$HOUR_START" "$HOUR_END" "hour ${HOUR_STR}:00-${HOUR_STR}:59")

      if [ "$HOUR_RESULT_COUNT" -eq 100 ]; then
        echo "    WARNING: Hour ${HOUR_STR} hit 100 result limit, re-querying in 5-minute blocks"
        for MIN in {0..55..5}; do
          MIN_STR=$(printf "%02d" $MIN)
          MIN_END_MIN=$(printf "%02d" $((MIN + 4)))
          MIN_START="${HOUR_STR}${MIN_STR}00"
          MIN_END_TIME="${HOUR_STR}${MIN_END_MIN}59"

          MIN_RESULT_COUNT=$(query_block "$CURR_DATE" "$MIN_START" "$MIN_END_TIME" "5-min ${HOUR_STR}:${MIN_STR}-${HOUR_STR}:${MIN_END_MIN}")
          DAY_TOTAL=$((DAY_TOTAL + MIN_RESULT_COUNT))
          if [ "$MIN_RESULT_COUNT" -eq 100 ]; then
            printf >&2 "    ERROR: 5-minute block ${HOUR_STR}:${MIN_STR} also hit 100 result limit. Results may be incomplete!\n"
          fi
        done
      else
        DAY_TOTAL=$((DAY_TOTAL + HOUR_RESULT_COUNT))
      fi
    done
    echo "  Total found for $CURR_DATE: $DAY_TOTAL results"
  else
    echo "  Found $DAY_RESULT_COUNT results"
  fi

  CURR_DATE=$(date +"%Y%m%d" -ud "$CURR_DATE UTC + 1 day")
  [ "$CURR_DATE" -le "$END_DATE" ] || break
done

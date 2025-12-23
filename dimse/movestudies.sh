#!/bin/bash

# Configuration
INPUT_FILE=""
CONCURRENCY=5
LOG_FILE="movescu_results.log"

# DICOM Connectivity Defaults (overridable via CLI flags)
AEC="SOMEPACSAE"   # Called AE Title
AET="MYAE"   # Calling AE Title
AEM="MOVEAE"   # Move Destination AE Title
DEST_IP=""         # PACS IP Address (REQUIRED)
DEST_PORT="104"     # PACS Port

usage() {
    cat <<EOF
Usage: $0 -i <input.jsonl> -H <dest_ip> [options]
  -i <file>     JSONL file containing study_uid fields
  -p <num>      Number of parallel moves (default: ${CONCURRENCY})
  -H <ip>       Destination PACS IP (required)
  -P <port>     Destination PACS Port (default: ${DEST_PORT})
  -C <aec>      Called AE Title (default: ${AEC})
  -A <aet>      Calling AE Title (default: ${AET})
  -M <aem>      Move Destination AE Title (default: ${AEM})
  -h            Show this help
EOF
    exit 1
}

# 1. Check Dependencies
for cmd in jq movescu xargs; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found."
        exit 1
    fi
done

# 2. Parse CLI options
while getopts "i:p:H:P:C:A:M:h" opt; do
    case "$opt" in
        i) INPUT_FILE=$OPTARG ;;
        p) CONCURRENCY=$OPTARG ;;
        H) DEST_IP=$OPTARG ;;
        P) DEST_PORT=$OPTARG ;;
        C) AEC=$OPTARG ;;
        A) AET=$OPTARG ;;
        M) AEM=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
    echo "Error: Valid input file required."
    usage
fi

# Require destination IP; other connectivity params use defaults if not provided
if [[ -z "$DEST_IP" ]]; then
    echo "Error: Destination IP (-H) is required."
    usage
fi

echo "Starting moves from $INPUT_FILE with concurrency $CONCURRENCY..."
echo "Using AEC=$AEC AET=$AET AEM=$AEM DEST=$DEST_IP:$DEST_PORT"
echo "Logging results to $LOG_FILE"
echo "--- Started: $(date) ---" >> "$LOG_FILE"

# 3. Define the Move Function
# This function is exported so xargs can call it in a subshell
do_move() {
    local uid=$1
    local log=$2
    local aec=$3
    local aet=$4
    local aem=$5
    local ip=$6
    local port=$7

    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting move for: $uid" >> "$log"

    # Execute movescu
    if movescu -v -S \
        -k QueryRetrieveLevel=STUDY \
        -aec "$aec" \
        -aet "$aet" \
        -aem "$aem" \
        -k StudyInstanceUID="$uid" \
        "$ip" "$port" >> "$log" 2>&1; then
        echo "[SUCCESS] Study: $uid" >> "$log"
    else
        echo "[FAILURE] Study: $uid - Check log above for details" >> "$log"
    fi
}

# Export the function and variables so they are available to xargs
export -f do_move
export LOG_FILE AEC AET AEM DEST_IP DEST_PORT

# 4. Process the JSONL and pipe to xargs
# -r: Raw output (no quotes)
# -P: Max parallel processes
# -I: Replace {} with the input string
jq -r '.study_uid' "$INPUT_FILE" | \
    xargs -I {} -P "$CONCURRENCY" \
    bash -c 'do_move "{}" "$LOG_FILE" "$AEC" "$AET" "$AEM" "$DEST_IP" "$DEST_PORT"'

echo "Completed. Check $LOG_FILE for details."

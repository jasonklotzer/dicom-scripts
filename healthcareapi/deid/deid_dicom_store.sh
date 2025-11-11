#!/usr/bin/env bash
set -euo pipefail

# De-identification script for DICOM stores using Google Cloud Healthcare API v1beta1
# This script creates a de-identified copy of a source DICOM store in a destination DICOM store

# Default values
VERBOSE=false
WAIT_FOR_COMPLETION=true
POLL_INTERVAL=30

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

reqCmdExists() {
  command -v $1 >/dev/null 2>&1 || { fail "Command '$1' is required, but not installed."; }
}

usage() {
  cat << EOF
Usage: $0 -s <sourceStore> -d <destStore> [options]

Required arguments:
  -s <sourceStore>       Source DICOM store path
                         Format: projects/PROJECT_ID/locations/LOCATION/datasets/DATASET_ID/dicomStores/SOURCE_STORE
  -d <destStore>         Destination DICOM store path (must already exist)
                         Format: projects/PROJECT_ID/locations/LOCATION/datasets/DATASET_ID/dicomStores/DEST_STORE

Options:
  -v                     Verbose output (show API responses and progress)
  -n                     No-wait mode (don't wait for operation to complete)
  -i <seconds>           Poll interval when waiting for completion (default: 30)
  -h                     Show this help message

De-identification Configuration:
  This script uses the following built-in configuration:
  - ProfileType: ATTRIBUTE_CONFIDENTIALITY_BASIC_PROFILE
  - TextRedactionMode: REDACT_SENSITIVE_TEXT_CLEAN_DESCRIPTORS

Examples:
  # Basic de-identification
  $0 -s projects/my-project/locations/us-central1/datasets/source-ds/dicomStores/original \\
     -d projects/my-project/locations/us-central1/datasets/dest-ds/dicomStores/deidentified

  # With verbose output and custom poll interval
  $0 -s projects/my-project/locations/us-central1/datasets/source-ds/dicomStores/original \\
     -d projects/my-project/locations/us-central1/datasets/dest-ds/dicomStores/deidentified \\
     -v -i 10

  # Start operation but don't wait for completion
  $0 -s projects/my-project/locations/us-central1/datasets/source-ds/dicomStores/original \\
     -d projects/my-project/locations/us-central1/datasets/dest-ds/dicomStores/deidentified \\
     -n
EOF
  exit 0
}

# Parse command line arguments
while getopts "s:d:vi:nh" opt; do
  case $opt in
    s) SOURCE_STORE="$OPTARG" ;;
    d) DEST_STORE="$OPTARG" ;;
    v) VERBOSE=true ;;
    n) WAIT_FOR_COMPLETION=false ;;
    i) POLL_INTERVAL="$OPTARG" ;;
    h) usage ;;
    \?) fail "Invalid option: -$OPTARG" ;;
  esac
done

# Validate required commands
REQ_COMMANDS="gcloud curl jq"
for COMMAND in $REQ_COMMANDS; do 
  reqCmdExists ${COMMAND}
done

# Validate required arguments
[ -z "${SOURCE_STORE:-}" ] && fail "Source DICOM store is required (-s)"
[ -z "${DEST_STORE:-}" ] && fail "Destination DICOM store is required (-d)"

# Validate store path formats
if [[ ! "$SOURCE_STORE" =~ ^projects/[^/]+/locations/[^/]+/datasets/[^/]+/dicomStores/[^/]+$ ]]; then
  fail "Invalid source store format. Expected: projects/PROJECT/locations/LOCATION/datasets/DATASET/dicomStores/STORE"
fi

if [[ ! "$DEST_STORE" =~ ^projects/[^/]+/locations/[^/]+/datasets/[^/]+/dicomStores/[^/]+$ ]]; then
  fail "Invalid destination store format. Expected: projects/PROJECT/locations/LOCATION/datasets/DATASET/dicomStores/STORE"
fi

# Validate numeric arguments
[[ ! "$POLL_INTERVAL" =~ ^[0-9]+$ ]] && fail "Poll interval must be a positive integer"
[ "$POLL_INTERVAL" -lt 1 ] && fail "Poll interval must be at least 1 second"

echo "=== DICOM Store De-identification ==="
echo "Source Store: ${SOURCE_STORE}"
echo "Destination Store: ${DEST_STORE}"
echo "Profile: ATTRIBUTE_CONFIDENTIALITY_BASIC_PROFILE"
echo "Text Redaction: REDACT_SENSITIVE_TEXT_CLEAN_DESCRIPTORS"
[ "$WAIT_FOR_COMPLETION" = true ] && echo "Will wait for completion (poll interval: ${POLL_INTERVAL}s)"
[ "$WAIT_FOR_COMPLETION" = false ] && echo "Will NOT wait for completion"
echo "======================================"
echo ""

# Get authentication token
if [ "$VERBOSE" = true ]; then
  echo "Getting authentication token..."
fi
BEARER_TOKEN=$(gcloud auth application-default print-access-token)

# Create the de-identification request payload
DEID_CONFIG=$(cat << 'EOF'
{
  "config": {
    "dicom_tag_config": {
      "profile_type": "DEIDENTIFY_TAG_CONTENTS",
      "options": {
        "clean_image": {
          "text_redaction_mode": "REDACT_ALL_TEXT"
        }
      }
    }
  },
  "destination_store": ""
}
EOF
)

# DEID_CONFIG=$(cat << 'EOF'
# {
#   "config": {
#     "dicom_tag_config": {
#       "profile_type": "DEIDENTIFY_TAG_CONTENTS",
#       "options": {
#         "clean_image": {
#           "text_redaction_mode": "REDACT_SENSITIVE_TEXT_CLEAN_DESCRIPTORS"
#         }
#       }
#     }
#   },
#   "destination_store": ""
# }
# EOF
# )

# Update the destination store in the payload
DEID_CONFIG=$(echo "$DEID_CONFIG" | jq --arg dest "$DEST_STORE" '.destination_store = $dest')

if [ "$VERBOSE" = true ]; then
  echo "De-identification configuration:"
  echo "$DEID_CONFIG" | jq .
  echo ""
fi

# Submit the de-identification request
echo "Submitting de-identification request..."
API_URL="https://healthcare.googleapis.com/v1beta1/${SOURCE_STORE}:deidentify"

RESPONSE=$(curl -X POST \
  --silent \
  --fail \
  -H "Authorization: Bearer ${BEARER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$DEID_CONFIG" \
  "$API_URL")

if [ "$VERBOSE" = true ]; then
  echo "API Response:"
  echo "$RESPONSE" | jq .
  echo ""
fi

# Extract operation name
OPERATION_NAME=$(echo "$RESPONSE" | jq -r '.name // empty')

if [ -z "$OPERATION_NAME" ]; then
  echo "Failed to extract operation name from response:"
  echo "$RESPONSE" | jq .
  exit 1
fi

echo "De-identification operation started: $OPERATION_NAME"

# If not waiting for completion, exit here
if [ "$WAIT_FOR_COMPLETION" = false ]; then
  echo ""
  echo "Operation started successfully. To check status later, run:"
  echo "gcloud healthcare operations describe $OPERATION_NAME"
  exit 0
fi

# Wait for operation to complete
echo "Waiting for operation to complete (polling every ${POLL_INTERVAL}s)..."
echo "Press Ctrl+C to stop waiting (operation will continue in background)"
echo ""

OPERATION_URL="https://healthcare.googleapis.com/v1beta1/${OPERATION_NAME}"
START_TIME=$(date +%s)

while true; do
  sleep $POLL_INTERVAL
  
  ELAPSED=$(($(date +%s) - START_TIME))
  
  # Check operation status
  OP_RESPONSE=$(curl -X GET \
    --silent \
    --fail \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    "$OPERATION_URL")
  
  if [ "$VERBOSE" = true ]; then
    echo "Operation status response:"
    echo "$OP_RESPONSE" | jq .
    echo ""
  fi
  
  # Check if operation is done
  DONE=$(echo "$OP_RESPONSE" | jq -r '.done // false')
  
  if [ "$DONE" = "true" ]; then
    echo "Operation completed after ${ELAPSED} seconds!"
    
    # Check for errors
    ERROR=$(echo "$OP_RESPONSE" | jq -r '.error // empty')
    if [ -n "$ERROR" ] && [ "$ERROR" != "null" ]; then
      echo ""
      echo "=== Operation Failed ==="
      echo "$OP_RESPONSE" | jq -r '.error'
      exit 1
    fi
    
    # Show success response
    echo ""
    echo "=== De-identification Successful ==="
    RESPONSE_SUMMARY=$(echo "$OP_RESPONSE" | jq -r '.response // {}')
    
    if [ "$RESPONSE_SUMMARY" != "{}" ] && [ "$RESPONSE_SUMMARY" != "null" ]; then
      echo "Operation response:"
      echo "$RESPONSE_SUMMARY" | jq .
    else
      echo "De-identification completed successfully!"
      echo "De-identified DICOM data is now available in: $DEST_STORE"
    fi
    break
  else
    # Show progress if available
    METADATA=$(echo "$OP_RESPONSE" | jq -r '.metadata // {}')
    
    if [ "$METADATA" != "{}" ] && [ "$METADATA" != "null" ]; then
      # Try to extract progress information if available
      PROGRESS_PERCENT=$(echo "$METADATA" | jq -r '.progressPercent // empty')
      if [ -n "$PROGRESS_PERCENT" ] && [ "$PROGRESS_PERCENT" != "null" ]; then
        printf "\rProgress: ${PROGRESS_PERCENT}%% | Elapsed: ${ELAPSED}s"
      else
        printf "\rOperation in progress | Elapsed: ${ELAPSED}s"
      fi
    else
      printf "\rOperation in progress | Elapsed: ${ELAPSED}s"
    fi
  fi
done

echo ""
echo ""
echo "De-identification operation completed successfully!"
echo "Source: $SOURCE_STORE"
echo "Destination: $DEST_STORE"
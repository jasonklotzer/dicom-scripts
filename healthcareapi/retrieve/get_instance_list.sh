#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   get_instance_list.sh <DICOM_WEB_BASE> [--frames] [--output FILE]
# Example DICOM_WEB_BASE:
#   projects/data-axe-350723/locations/us-central1/datasets/ds1/dicomStores/test/dicomWeb
#
# Requirements: gcloud, jq, curl
#
# This script queries the DICOMweb QIDO-RS endpoints:
#   /studies
#   /studies/{study}/series
#   /studies/{study}/series/{series}/instances
# and prints full DICOMweb instance paths:
#   <DICOM_WEB_BASE>/studies/{study}/series/{series}/instances/{instance}
#
# Pass --frames to append /frames/1 to each instance URL.

print_usage() {
  sed -n '1,120p' <<'USAGE'
Usage: get_instance_list.sh <DICOM_WEB_BASE> [--frames] [--output FILE]

<DICOM_WEB_BASE> example:
  projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb

Options:
  --frames        Append /frames/1 to each instance path
  --output FILE   Write results to FILE (default: stdout)
USAGE
}

if [[ "${1:-}" == "" ]]; then
  print_usage
  exit 1
fi

DICOM_BASE="$1"
shift || true

APPEND_FRAMES=false
OUTFILE=""

while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --frames) APPEND_FRAMES=true; shift ;;
    --output) OUTFILE="$2"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 2 ;;
  esac
done

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found. Install/configure gcloud and authenticate."
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found. Install jq to parse JSON."
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found."
  exit 2
fi

TOKEN="$(gcloud auth print-access-token)"

# Helper: perform GET request to DICOMweb endpoint path (relative to $DICOM_BASE)
fetch() {
  local path="$1"
  curl -s -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/dicom+json" \
    "https://healthcare.googleapis.com/v1/${DICOM_BASE}/${path}"
}

# Extract StudyInstanceUIDs
studies_json="$(fetch 'studies')"
# Most DICOM JSONs place StudyInstanceUID under tag "0020000D". Fallback to scanning raw JSON if jq path missing.
study_uids=()
while IFS= read -r uid; do
  [[ -n "$uid" ]] && study_uids+=("$uid")
done < <(echo "$studies_json" | jq -r '.[].["0020000D"].Value[0] // empty')

if [[ ${#study_uids[@]} -eq 0 ]]; then
  # fallback: try to extract any strings that look like a UID
  while IFS= read -r uid; do
    [[ -n "$uid" ]] && study_uids+=("$uid")
  done < <(echo "$studies_json" | grep -oP '[0-9]+\.[0-9\.]+' | sort -u)
fi

if [[ ${#study_uids[@]} -eq 0 ]]; then
  echo "No studies found or unable to parse StudyInstanceUIDs."
  exit 0
fi

echo "Found ${#study_uids[@]} studies" >&2

# Build list of instance paths
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT

study_count=0
for study in "${study_uids[@]}"; do
  study_count=$((study_count + 1))
  echo "Processing study ${study_count}/${#study_uids[@]}: ${study}" >&2
  series_json="$(fetch "studies/${study}/series")"
  # SeriesInstanceUID tag: "0020000E"
  series_uids=()
  while IFS= read -r uid; do
    [[ -n "$uid" ]] && series_uids+=("$uid")
  done < <(echo "$series_json" | jq -r '.[].["0020000E"].Value[0] // empty')

  if [[ ${#series_uids[@]} -eq 0 ]]; then
    # fallback
    while IFS= read -r uid; do
      [[ -n "$uid" ]] && series_uids+=("$uid")
    done < <(echo "$series_json" | grep -oP '[0-9]+\.[0-9\.]+' | sort -u)
  fi

  echo "  Found ${#series_uids[@]} series in study ${study_count}" >&2

  series_count=0
  for series in "${series_uids[@]}"; do
    series_count=$((series_count + 1))
    instances_json="$(fetch "studies/${study}/series/${series}/instances")"
    # SOP Instance UID tag: "00080018"
    inst_uids=()
    while IFS= read -r uid; do
      [[ -n "$uid" ]] && inst_uids+=("$uid")
    done < <(echo "$instances_json" | jq -r '.[].["00080018"].Value[0] // empty')

    if [[ ${#inst_uids[@]} -eq 0 ]]; then
      # fallback
      while IFS= read -r uid; do
        [[ -n "$uid" ]] && inst_uids+=("$uid")
      done < <(echo "$instances_json" | grep -oP '[0-9]+\.[0-9\.]+' | sort -u)
    fi

    echo "    Series ${series_count}/${#series_uids[@]}: Found ${#inst_uids[@]} instances" >&2

    for inst in "${inst_uids[@]}"; do
      path="${DICOM_BASE}/studies/${study}/series/${series}/instances/${inst}"
      if $APPEND_FRAMES; then
        path="${path}/frames/1"
      fi
      echo "$path" >> "$tmpfile"
    done
  done
done

# Count total instances
total_instances=$(wc -l < "$tmpfile")
echo "Total instances found: ${total_instances}" >&2

# Output
if [[ -n "$OUTFILE" ]]; then
  mv "$tmpfile" "$OUTFILE"
  echo "Wrote instance list to $OUTFILE" >&2
else
  cat "$tmpfile"
fi
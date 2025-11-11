#!/bin/bash

set -e

REQ_COMMANDS="gcloud curl bc"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Default values
PARALLEL_REQUESTS=10
MAX_REQUESTS=0
DURATION_SECONDS=0
VERBOSE=false
OUTPUT_DIR="./output"
GENERATE_GRAPH=false
REQUEST_TIMEOUT=20
MAX_RETRIES=3
RETRY_DELAY=1
RANDOMIZE=false

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

reqCmdExists() {
  command -v $1 >/dev/null 2>&1 || { fail "Command '$1' is required, but not installed."; }
}

usage() {
  cat << EOF
Usage: $0 -f <pathsFile> [options]

Required arguments:
  -f <pathsFile>         File containing a list of DICOMweb paths (one per line).
                         The level (study/series/instance/frame) is auto-detected from the paths.
                         Examples of paths in the file:
                           Study:    .../dicomWeb/studies/1.2.3.4
                           Series:   .../dicomWeb/studies/1.2.3.4/series/1.2.3.5
                           Instance: .../dicomWeb/studies/1.2.3.4/series/1.2.3.5/instances/1.2.3.6
                           Frame:    .../dicomWeb/studies/1.2.3.4/series/1.2.3.5/instances/1.2.3.6/frames/1


Performance Options:
  -p <number>            Number of parallel requests (default: 10)
  -n <number>            Total number of requests to send (default: unlimited, requires -d)
  -d <seconds>           Duration to run the test in seconds (default: unlimited, requires -n)
  -t <seconds>           Per-request timeout in seconds (default: 20)
  -r <number>            Maximum number of retries for HTTP 429 errors (default: 3, 0 to disable)
  -R                     Randomize the order of paths (default: sequential)
  -v                     Verbose output (show individual request results)
  -o <directory>         Output directory to save results and graphs (default: ./output)
  -g                     Generate graphs (requires gnuplot to be installed)
  -h                     Show this help message

Examples:
  # Test with instance list
  $0 -f instances.txt -n 100 -p 10

  # Test with time limit
  $0 -f instances.txt -d 60 -p 5

  # Test with larger parallelism
  $0 -f instances.txt -n 200 -p 15

  # Test with graph generation
  $0 -f instances.txt -n 1000 -p 10 -o ./results -g
EOF
  exit 0
}

# Parse command line arguments
while getopts "f:p:n:d:t:r:o:Rgvh" opt; do
  case $opt in
    f) PATHS_FILE="$OPTARG" ;;
    p) PARALLEL_REQUESTS="$OPTARG" ;;
    n) MAX_REQUESTS="$OPTARG" ;;
    d) DURATION_SECONDS="$OPTARG" ;;
    t) REQUEST_TIMEOUT="$OPTARG" ;;
    r) MAX_RETRIES="$OPTARG" ;;
    R) RANDOMIZE=true ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    g) GENERATE_GRAPH=true ;;
    v) VERBOSE=true ;;
    h) usage ;;
    \?) fail "Invalid option: -$OPTARG" ;;
  esac
done

# Validate required commands
for COMMAND in $REQ_COMMANDS; do reqCmdExists ${COMMAND}; done

# Validate required arguments
[ -z "$PATHS_FILE" ] && fail "Paths file is required (-f)"
[ ! -f "$PATHS_FILE" ] && fail "Paths file not found: $PATHS_FILE"
[ ! -r "$PATHS_FILE" ] && fail "Paths file is not readable: $PATHS_FILE"

# Read paths into array and normalize them
DICOMWEB_PATHS=()
HCAPI_HOST=https://healthcare.googleapis.com/v1

while IFS= read -r line || [ -n "$line" ]; do
  # Skip empty lines and comments
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  
  # Normalize the path - add https prefix if not present
  if [[ ! "$line" =~ ^https?:// ]]; then
    # Remove leading slash if present
    line="${line#/}"
    line="${HCAPI_HOST}/${line}"
  fi
  
  DICOMWEB_PATHS+=("$line")
done < "$PATHS_FILE"

# Validate we have paths
[ ${#DICOMWEB_PATHS[@]} -eq 0 ] && fail "No valid paths found in $PATHS_FILE"

# Auto-detect the level based on the first path (assume all paths are same level)
FIRST_PATH="${DICOMWEB_PATHS[0]}"
if [[ "$FIRST_PATH" =~ /frames/[^/]+$ ]]; then
  LEVEL="frame"
elif [[ "$FIRST_PATH" =~ /instances/[^/]+$ ]]; then
  LEVEL="instance"
elif [[ "$FIRST_PATH" =~ /series/[^/]+$ ]]; then
  LEVEL="series"
elif [[ "$FIRST_PATH" =~ /studies/[^/]+$ ]]; then
  LEVEL="study"
else
  fail "Invalid DICOMweb path format in file. Paths must end with /studies/<uid>, /series/<uid>, /instances/<uid>, or /frames/<number>"
fi

# Validate that at least one stopping condition is provided
if [ "$MAX_REQUESTS" -eq 0 ] && [ "$DURATION_SECONDS" -eq 0 ]; then
  fail "Must specify either -n (max requests) or -d (duration) or both"
fi

# Validate numeric arguments
[[ ! "$PARALLEL_REQUESTS" =~ ^[0-9]+$ ]] && fail "Parallel requests must be a positive integer"
[[ ! "$MAX_REQUESTS" =~ ^[0-9]+$ ]] && fail "Max requests must be a non-negative integer"
[[ ! "$DURATION_SECONDS" =~ ^[0-9]+$ ]] && fail "Duration must be a non-negative integer"
[[ ! "$MAX_RETRIES" =~ ^[0-9]+$ ]] && fail "Max retries must be a non-negative integer"
[ "$PARALLEL_REQUESTS" -lt 1 ] && fail "Parallel requests must be at least 1"

# Validate graph options
if [ "$GENERATE_GRAPH" = true ]; then
  command -v gnuplot >/dev/null 2>&1 || fail "Graph generation requires 'gnuplot' to be installed"
fi

# Setup output directory - create it and convert to absolute path
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

# Get authentication token

BEARER_TOKEN=$(gcloud auth application-default print-access-token)
TEMP_DIR=$(mktemp -d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="${OUTPUT_DIR}/results_${TIMESTAMP}.txt"
STOP_FLAG="${TEMP_DIR}/stop"

# Clean up temp dir on exit
trap "rm -rf ${TEMP_DIR}" EXIT

# Create a file with all paths for workers to consume
PATHS_QUEUE="${TEMP_DIR}/paths_queue.txt"
PATHS_INDEX="${TEMP_DIR}/paths_index.txt"

# Write paths with their original indices (0-based)
for i in "${!DICOMWEB_PATHS[@]}"; do
  echo "$i|${DICOMWEB_PATHS[$i]}" >> "$PATHS_INDEX"
done

if [ "$RANDOMIZE" = true ]; then
  # Shuffle the paths while preserving the index
  shuf "$PATHS_INDEX" > "$PATHS_QUEUE"
  echo "=== DICOM Retrieval Performance Test ==="
  echo "Paths File: ${PATHS_FILE}"
  echo "Total Paths: ${#DICOMWEB_PATHS[@]} (RANDOMIZED)"
else
  cp "$PATHS_INDEX" "$PATHS_QUEUE"
  echo "=== DICOM Retrieval Performance Test ==="
  echo "Paths File: ${PATHS_FILE}"
  echo "Total Paths: ${#DICOMWEB_PATHS[@]}"
fi

echo "Detected Level: ${LEVEL}"
echo "Parallel Requests: ${PARALLEL_REQUESTS}"
[ "$MAX_REQUESTS" -gt 0 ] && echo "Max Requests: ${MAX_REQUESTS}"
[ "$DURATION_SECONDS" -gt 0 ] && echo "Duration: ${DURATION_SECONDS} seconds"
echo "========================================"
echo ""

# Worker function to perform a single request
do_request() {
  local worker_id=$1
  local bearer_token=$2
  local path_index=$3
  local dicomweb_path=$4
  local results_file=$5
  local stop_flag=$6
  local verbose=$7
  local max_retries=$8
  
  local attempt=0
  local retry_delay=${RETRY_DELAY}
  local http_result=""
  local total_time_ms=0
  local bytes_downloaded=0
  
  START_MS=$(date +%s%3N)
  
  while [ $attempt -le $max_retries ]; do
    local attempt_start=$(date +%s%3N)
    
    # Perform the retrieval request
    curl_output=$(curl -X GET \
      --silent \
      --output /dev/null \
      --write-out "%{http_code}|%{size_download}" \
      --max-time ${REQUEST_TIMEOUT} \
      -H "Authorization: Bearer ${bearer_token}" \
      "${dicomweb_path}")
    
    http_result=$(echo "$curl_output" | cut -d'|' -f1)
    bytes_downloaded=$(echo "$curl_output" | cut -d'|' -f2)
    
    local attempt_end=$(date +%s%3N)
    local attempt_time=$((attempt_end - attempt_start))
    
    # If successful or not a 429 error, break
    if [ "$http_result" != "429" ] || [ $max_retries -eq 0 ]; then
      END_MS=$(date +%s%3N)
      total_time_ms=$((END_MS - START_MS))
      break
    fi
    
    # If we've exhausted retries, break
    if [ $attempt -ge $max_retries ]; then
      END_MS=$(date +%s%3N)
      total_time_ms=$((END_MS - START_MS))
      break
    fi
    
    # Retry with exponential backoff
    attempt=$((attempt + 1))
    local backoff_time=$(echo "$retry_delay * (2 ^ ($attempt - 1))" | bc)
    
    if [ "$verbose" = true ]; then
      echo "[Worker $worker_id] ⚠ HTTP 429 - Retry $attempt/$max_retries after ${backoff_time}s"
    fi
    
    sleep $backoff_time
  done
  
  # Write result: http_code|response_time_ms|retry_count|path_index|bytes_downloaded
  echo "${http_result}|${total_time_ms}|${attempt}|${path_index}|${bytes_downloaded}" >> "$results_file"
  
  if [ "$verbose" = true ]; then
    if [ "$http_result" = "200" ]; then
      local kb_size=$(echo "scale=1; $bytes_downloaded / 1024" | bc -l)
      if [ $attempt -gt 0 ]; then
        echo "[Worker $worker_id] ✓ HTTP ${http_result} - ${total_time_ms}ms - ${kb_size}KB (path ${path_index}, retried $attempt times)"
      else
        echo "[Worker $worker_id] ✓ HTTP ${http_result} - ${total_time_ms}ms - ${kb_size}KB (path ${path_index})"
      fi
    elif [ "$http_result" = "429" ] && [ $attempt -gt 0 ]; then
      echo "[Worker $worker_id] ✗ HTTP ${http_result} - ${total_time_ms}ms (path ${path_index}, FAILED after $attempt retries)"
    else
      echo "[Worker $worker_id] ✗ HTTP ${http_result} - ${total_time_ms}ms (path ${path_index}, FAILED)"
    fi
  fi
  
  return 0
}

# Worker process - now picks paths from the queue
worker() {
  local worker_id=$1
  local bearer_token=$2
  local paths_queue=$3
  local results_file=$4
  local stop_flag=$5
  local verbose=$6
  local max_retries=$7
  local line_num=0
  local total_paths=$(wc -l < "$paths_queue")
  
  while [ ! -f "$stop_flag" ]; do
    # Get next path (cycle through the list)
    line_num=$((line_num + 1))
    if [ $line_num -gt $total_paths ]; then
      line_num=1
    fi
    
    local line=$(sed -n "${line_num}p" "$paths_queue")
    
    # Safety check
    if [ -z "$line" ]; then
      continue
    fi
    
    # Parse index and path (format: index|path)
    local path_index=$(echo "$line" | cut -d'|' -f1)
    local dicomweb_path=$(echo "$line" | cut -d'|' -f2-)
    
    do_request "$worker_id" "$bearer_token" "$path_index" "$dicomweb_path" "$results_file" "$stop_flag" "$verbose" "$max_retries"
  done
}


# Start workers and track their PIDs
WORKER_PIDS=()
for i in $(seq 1 $PARALLEL_REQUESTS); do
  worker "$i" "$BEARER_TOKEN" "$PATHS_QUEUE" "$RESULTS_FILE" "$STOP_FLAG" "$VERBOSE" "$MAX_RETRIES" &
  WORKER_PIDS+=("$!")
done

START_TIME=$(date +%s)
REQUEST_COUNT=0

# Monitor progress
while true; do
  sleep 1
  
  if [ -f "$RESULTS_FILE" ]; then
    REQUEST_COUNT=$(wc -l < "$RESULTS_FILE")
  fi
  
  ELAPSED=$(($(date +%s) - START_TIME))
  
  # Check stopping conditions
  SHOULD_STOP=false
  
  if [ "$MAX_REQUESTS" -gt 0 ] && [ "$REQUEST_COUNT" -ge "$MAX_REQUESTS" ]; then
    SHOULD_STOP=true
    echo " | Reached max requests limit!"
  fi
  
  if [ "$DURATION_SECONDS" -gt 0 ] && [ "$ELAPSED" -ge "$DURATION_SECONDS" ]; then
    SHOULD_STOP=true
    echo " | Reached time limit!"
  fi
  
  if [ "$SHOULD_STOP" = true ]; then
    touch "$STOP_FLAG"
    break
  fi
  
  # Progress update
  if [ "$VERBOSE" = false ]; then
    printf "\rRequests: %d | Elapsed: %ds | Rate: %.2f req/s" \
      "$REQUEST_COUNT" \
      "$ELAPSED" \
      $(echo "scale=2; $REQUEST_COUNT / $ELAPSED" | bc -l)
  fi
done


# Wait for all workers to finish, but after stop flag is set, kill any that are still running
for pid in "${WORKER_PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    wait "$pid" || true
  fi
done

# After waiting, forcibly kill any remaining worker processes (shouldn't be needed, but just in case)
for pid in "${WORKER_PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
done

echo ""
echo ""
echo "=== Test Complete ==="

# Calculate statistics
if [ ! -f "$RESULTS_FILE" ] || [ ! -s "$RESULTS_FILE" ]; then
  echo "No results collected"
  exit 1
fi

TOTAL_REQUESTS=$(wc -l < "$RESULTS_FILE")
TOTAL_TIME=$(($(date +%s) - START_TIME))

# Parse results
SUCCESS_COUNT=$(grep -c "^200|" "$RESULTS_FILE" || true)
ERROR_COUNT=$((TOTAL_REQUESTS - SUCCESS_COUNT))

# Calculate timing statistics for successful requests
if [ "$SUCCESS_COUNT" -gt 0 ]; then
  TIMES=$(grep "^200|" "$RESULTS_FILE" | cut -d'|' -f2 | sort -n)
  
  MIN_TIME=$(echo "$TIMES" | head -n1)
  MAX_TIME=$(echo "$TIMES" | tail -n1)
  AVG_TIME=$(echo "$TIMES" | awk '{sum+=$1} END {print sum/NR}' | xargs printf "%.0f")
  
  # Calculate median
  MEDIAN_TIME=$(echo "$TIMES" | awk '{arr[NR]=$1} END {
    if (NR % 2 == 1) {
      print arr[(NR+1)/2]
    } else {
      print (arr[NR/2] + arr[NR/2+1])/2
    }
  }' | xargs printf "%.0f")
  
  # Calculate 90th percentile
  P90_INDEX=$(echo "scale=0; ($SUCCESS_COUNT * 90) / 100" | bc)
  [ "$P90_INDEX" -lt 1 ] && P90_INDEX=1
  P90_TIME=$(echo "$TIMES" | sed -n "${P90_INDEX}p")
fi

# Parse results (now with retry column)
SUCCESS_COUNT=$(grep -c "^200|" "$RESULTS_FILE" || true)
ERROR_COUNT=$((TOTAL_REQUESTS - SUCCESS_COUNT))

# Count retried requests (any with retry count > 0)
# Note: Format is now http_code|response_time|retries|path_index|bytes_downloaded
RETRIED_COUNT=$(awk -F'|' '$3 > 0 {c++} END {print c+0}' "$RESULTS_FILE")
RETRIED_SUCCESS=$(awk -F'|' '$1=="200" && $3 > 0 {c++} END {print c+0}' "$RESULTS_FILE")

# Calculate timing statistics for successful requests
if [ "$SUCCESS_COUNT" -gt 0 ]; then
  TIMES=$(grep "^200|" "$RESULTS_FILE" | cut -d'|' -f2 | sort -n)
  
  MIN_TIME=$(echo "$TIMES" | head -n1)
  MAX_TIME=$(echo "$TIMES" | tail -n1)
  AVG_TIME=$(echo "$TIMES" | awk '{sum+=$1} END {print sum/NR}' | xargs printf "%.0f")
  
  # Calculate median
  MEDIAN_TIME=$(echo "$TIMES" | awk '{arr[NR]=$1} END {
    if (NR % 2 == 1) {
      print arr[(NR+1)/2]
    } else {
      print (arr[NR/2] + arr[NR/2+1])/2
    }
  }' | xargs printf "%.0f")
  
  # Calculate 90th percentile
  P90_INDEX=$(echo "scale=0; ($SUCCESS_COUNT * 90) / 100" | bc)
  [ "$P90_INDEX" -lt 1 ] && P90_INDEX=1
  P90_TIME=$(echo "$TIMES" | sed -n "${P90_INDEX}p")
fi

# Calculate data throughput statistics
TOTAL_BYTES_SUCCESS=0
if [ "$SUCCESS_COUNT" -gt 0 ]; then
  TOTAL_BYTES_SUCCESS=$(grep "^200|" "$RESULTS_FILE" | cut -d'|' -f5 | awk '{sum+=$1} END {print sum+0}')
fi

# Calculate throughput in various units
if [ "$TOTAL_BYTES_SUCCESS" -gt 0 ] && [ "$TOTAL_TIME" -gt 0 ]; then
  # Convert bytes to megabits (1 byte = 8 bits, 1 megabit = 1,000,000 bits)
  THROUGHPUT_MBPS=$(echo "scale=3; ($TOTAL_BYTES_SUCCESS * 8) / ($TOTAL_TIME * 1000000)" | bc -l)
else
  THROUGHPUT_MBPS="0.000"
fi

# Print statistics
echo "Total Requests: ${TOTAL_REQUESTS}"
echo "Duration: ${TOTAL_TIME} seconds"
echo "Request Rate: $(echo "scale=2; $TOTAL_REQUESTS / $TOTAL_TIME" | bc -l) requests/second"
if [ "$SUCCESS_COUNT" -gt 0 ]; then
  echo "Data Downloaded: $(echo "scale=2; $TOTAL_BYTES_SUCCESS / 1000000" | bc -l) MB (successful requests)"
  echo "Data Throughput: ${THROUGHPUT_MBPS} Mbits/sec"
fi
echo ""
echo "Success: ${SUCCESS_COUNT} ($(echo "scale=2; ($SUCCESS_COUNT * 100) / $TOTAL_REQUESTS" | bc -l)%)"
echo "Errors: ${ERROR_COUNT} ($(echo "scale=2; ($ERROR_COUNT * 100) / $TOTAL_REQUESTS" | bc -l)%)"
echo ""

echo "Retries: ${RETRIED_COUNT} ($(echo "scale=2; ($RETRIED_COUNT * 100) / $TOTAL_REQUESTS" | bc -l)%)"
echo "Successful with Retries: ${RETRIED_SUCCESS} ($(echo "scale=2; ($RETRIED_SUCCESS * 100) / $SUCCESS_COUNT" | bc -l)%)"
echo ""

if [ "$SUCCESS_COUNT" -gt 0 ]; then
  echo "=== Response Times (successful requests) ==="
  echo "Min: ${MIN_TIME}ms"
  echo "Max: ${MAX_TIME}ms"
  echo "Avg: ${AVG_TIME}ms"
  echo "Median: ${MEDIAN_TIME}ms"
  echo "P90: ${P90_TIME}ms"
fi

# Show error breakdown if any
if [ "$ERROR_COUNT" -gt 0 ]; then
  echo ""
  echo "=== Error Breakdown ==="
  grep -v "^200|" "$RESULTS_FILE" | cut -d'|' -f1 | sort | uniq -c | while read count code; do
    echo "HTTP ${code}: ${count} occurrences"
  done
fi

echo ""
echo "Test completed successfully!"

# Save results (always saved to OUTPUT_DIR)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_CSV="${OUTPUT_DIR}/results_${TIMESTAMP}.csv"
STATS_FILE="${OUTPUT_DIR}/stats_${TIMESTAMP}.txt"

echo ""
echo "=== Saving Results ==="
  
  # Save raw results as CSV (now with retries, path index, and bytes downloaded)
  echo "request_num,http_code,response_time_ms,retries,path_index,bytes_downloaded" > "$RESULTS_CSV"
  awk -F'|' '{print NR","$1","$2","$3","$4","$5}' "$RESULTS_FILE" >> "$RESULTS_CSV"
  echo "Raw results saved to: ${RESULTS_CSV}"
  
  # Save statistics summary
  cat > "$STATS_FILE" << EOF
DICOM Retrieval Performance Test Results
========================================
Test Date: $(date)
Paths File: ${PATHS_FILE}
Total Paths: ${#DICOMWEB_PATHS[@]}
Detected Level: ${LEVEL}
Parallel Requests: ${PARALLEL_REQUESTS}

Test Results
============
Total Requests: ${TOTAL_REQUESTS}
Duration: ${TOTAL_TIME} seconds
Request Rate: $(echo "scale=2; $TOTAL_REQUESTS / $TOTAL_TIME" | bc -l) requests/second
$(if [ "$SUCCESS_COUNT" -gt 0 ]; then
echo "Data Downloaded: $(echo "scale=2; $TOTAL_BYTES_SUCCESS / 1000000" | bc -l) MB (successful requests)"
echo "Data Throughput: ${THROUGHPUT_MBPS} Mbits/sec"
fi)

Success: ${SUCCESS_COUNT} ($(echo "scale=2; ($SUCCESS_COUNT * 100) / $TOTAL_REQUESTS" | bc -l)%)
Errors: ${ERROR_COUNT} ($(echo "scale=2; ($ERROR_COUNT * 100) / $TOTAL_REQUESTS" | bc -l)%)
  Retries: ${RETRIED_COUNT} ($(echo "scale=2; ($RETRIED_COUNT * 100) / $TOTAL_REQUESTS" | bc -l)%)
  Successful with Retries: ${RETRIED_SUCCESS} ($(echo "scale=2; ($RETRIED_SUCCESS * 100) / $SUCCESS_COUNT" | bc -l)%)

$(if [ "$SUCCESS_COUNT" -gt 0 ]; then
  echo "Response Times (successful requests)"
  echo "===================================="
  echo "Min: ${MIN_TIME}ms"
  echo "Max: ${MAX_TIME}ms"
  echo "Avg: ${AVG_TIME}ms"
  echo "Median: ${MEDIAN_TIME}ms"
  echo "P90: ${P90_TIME}ms"
fi)

$(if [ "$ERROR_COUNT" -gt 0 ]; then
  echo "Error Breakdown"
  echo "==============="
  grep -v "^200|" "$RESULTS_FILE" | cut -d'|' -f1 | sort | uniq -c | while read count code; do
    echo "HTTP ${code}: ${count} occurrences"
  done
  
  # Show which path indices had errors
  echo ""
  echo "=== Errors by Path Index ==="
  grep -v "^200|" "$RESULTS_FILE" | cut -d'|' -f4 | sort -n | uniq -c | sort -rn | head -20 | while read count idx; do
    echo "Path index ${idx}: ${count} errors"
  done
fi)
EOF
echo "Statistics saved to: ${STATS_FILE}"

# Generate graphs if requested
if [ "$GENERATE_GRAPH" = true ]; then
  echo ""
  echo "=== Generating Graphs ==="

  HISTOGRAM_PNG="${OUTPUT_DIR}/histogram_${TIMESTAMP}.png"
  TIMESERIES_PNG="${OUTPUT_DIR}/timeseries_${TIMESTAMP}.png"
  STATUS_PNG="${OUTPUT_DIR}/status_codes_${TIMESTAMP}.png"
  THROUGHPUT_PNG="${OUTPUT_DIR}/throughput_${TIMESTAMP}.png"
  COMBINED_PNG="${OUTPUT_DIR}/summary_${TIMESTAMP}.png"

  # Extract all requests with request number, http code, response time, retries, and bytes
  awk -F'|' '{print NR, $1, $2, $3, $5}' "$RESULTS_FILE" > "${TEMP_DIR}/all_requests.dat"

  # Extract successful and failed requests separately
  if [ "$SUCCESS_COUNT" -gt 0 ]; then
  awk -F'|' 'BEGIN{n=0} $1=="200" {n++; print n, $2}' "$RESULTS_FILE" > "${TEMP_DIR}/success_times.dat"
  fi

  if [ "$ERROR_COUNT" -gt 0 ]; then
    grep -v "^200|" "$RESULTS_FILE" | awk -F'|' '{print NR, $1, $2}' > "${TEMP_DIR}/error_requests.dat"
  fi

  # Precompute status code counts for gnuplot
  awk -F'|' '{print $1}' "$RESULTS_FILE" | sort | uniq -c | awk '{print $2, $1}' > "${TEMP_DIR}/status_codes.dat"

  # Generate HTTP status code distribution chart
  gnuplot 2>/dev/null << GNUPLOT_STATUS
set terminal png size 1200,600 font "Arial,12"
set output '${STATUS_PNG}'
set title "HTTP Status Code Distribution\n${TOTAL_REQUESTS} total requests"
set ylabel "Number of Requests"
set xlabel "HTTP Status Code"
set grid ytics
set style fill solid 0.7
set boxwidth 0.7 relative
set yrange [0:*]
set style data histogram
set style histogram cluster gap 1

plot "${TEMP_DIR}/status_codes.dat" using 2:xtic(1) with boxes lc rgb "blue" title "Request Count"
GNUPLOT_STATUS

  echo "Status code distribution saved to: ${STATUS_PNG}"

  if [ "$SUCCESS_COUNT" -gt 0 ]; then
    # Generate response time histogram (successful requests only)
    if [ -s "${TEMP_DIR}/success_times.dat" ]; then
      gnuplot 2>/dev/null << GNUPLOT_HISTOGRAM
set terminal png size 1200,600 font "Arial,12"
set output '${HISTOGRAM_PNG}'
set title "Response Time Distribution\n${LEVEL} level - ${SUCCESS_COUNT} requests"
set xlabel "Response Time (ms)"
set ylabel "Frequency"
set grid ytics
set style fill solid 0.5
set boxwidth 0.9 relative

# Calculate histogram bins
stats '${TEMP_DIR}/success_times.dat' using 2 nooutput
binwidth = (STATS_max - STATS_min) / 50
bin(x,width)=width*floor(x/width)

if (STATS_max > STATS_min) {
  plot '${TEMP_DIR}/success_times.dat' using (bin(column(2),binwidth)):(1.0) smooth freq with boxes lc rgb "blue" title "Response Time"
} else {
  set label 1 "Not enough data for histogram" at graph 0.5,0.5 center font "Arial,16"
  plot -1 notitle
}
GNUPLOT_HISTOGRAM
      echo "Histogram saved to: ${HISTOGRAM_PNG}"
    else
      # Create a dummy histogram if no data
      gnuplot 2>/dev/null << GNUPLOT_HISTOGRAM_EMPTY
set terminal png size 1200,600 font "Arial,12"
set output '${HISTOGRAM_PNG}'
set title "Response Time Distribution\n${LEVEL} level - 0 successful requests"
set xlabel "Response Time (ms)"
set ylabel "Frequency"
set label 1 "No successful requests to plot" at graph 0.5,0.5 center font "Arial,16"
plot -1 notitle
GNUPLOT_HISTOGRAM_EMPTY
      echo "Histogram saved to: ${HISTOGRAM_PNG} (empty)"
    fi
    
  # Generate time series graph with success/failure indicators
  gnuplot 2>/dev/null << GNUPLOT_TIMESERIES
stats '${TEMP_DIR}/all_requests.dat' using 3 nooutput
set terminal png size 1200,600 font "Arial,12"
set output '${TIMESERIES_PNG}'
set title "Response Time Over Test Duration\n${LEVEL} level - Success: ${SUCCESS_COUNT}, Failures: ${ERROR_COUNT}"
set xlabel "Request Number"
set ylabel "Response Time (ms)"
set grid
set key top left

stats '${TEMP_DIR}/all_requests.dat' using 3 nooutput

# Plot: blue = success, red = fail, orange = retried success
plot \
  '${TEMP_DIR}/all_requests.dat' using (\$2==200 && \$4==0?\$1:1/0):3 with points pt 7 ps 0.7 lc rgb "blue" title "Successful (no retry)", \
  '${TEMP_DIR}/all_requests.dat' using (\$2==200 && \$4>0?\$1:1/0):3 with points pt 9 ps 1 lc rgb "orange" title "Successful (retried)", \
  '${TEMP_DIR}/all_requests.dat' using (\$2!=200?\$1:1/0):3 with points pt 5 ps 1 lc rgb "red" title "Failed (non-200)", \
  ${AVG_TIME} with lines lc rgb "green" lw 2 title "Average (${AVG_TIME}ms)", \
  ${P90_TIME} with lines lc rgb "orange" lw 2 title "P90 (${P90_TIME}ms)"
GNUPLOT_TIMESERIES
    
    echo "Time series saved to: ${TIMESERIES_PNG}"

    # Generate throughput over time graph (successful requests only)
    if [ "$TOTAL_BYTES_SUCCESS" -gt 0 ]; then
      # First count total successful requests
      TOTAL_SUCCESS_REQUESTS=$(grep -c "^200|" "$RESULTS_FILE")
      
      # Create data file with proper cumulative throughput calculation
      grep "^200|" "$RESULTS_FILE" | awk -F'|' -v total_time="$TOTAL_TIME" -v total_success="$TOTAL_SUCCESS_REQUESTS" '
      BEGIN {
        cumulative_bytes = 0
        request_count = 0
      }
      {
        request_count++
        cumulative_bytes += $5
        # Estimate elapsed time based on request progress through the test
        elapsed_time = (request_count / total_success) * total_time
        if (elapsed_time > 0) {
          # Calculate cumulative throughput in Mbits/sec
          cumulative_throughput_mbps = (cumulative_bytes * 8) / (elapsed_time * 1000000)
          print request_count, cumulative_throughput_mbps, cumulative_bytes/1000000
        }
      }' > "${TEMP_DIR}/throughput_data.dat"

      if [ -s "${TEMP_DIR}/throughput_data.dat" ]; then
        gnuplot 2>/dev/null << GNUPLOT_THROUGHPUT
set terminal png size 1200,600 font "Arial,12"
set output '${THROUGHPUT_PNG}'
set title "Data Throughput Over Test Duration\n${LEVEL} level - Average: ${THROUGHPUT_MBPS} Mbits/sec"
set xlabel "Request Number"
set ylabel "Throughput (Mbits/sec)"
set y2label "Cumulative Data (MB)"
set grid
set key top left
set y2tics
set ytics nomirror

plot '${TEMP_DIR}/throughput_data.dat' using 1:2 with lines lc rgb "blue" lw 2 title "Cumulative Throughput (Mbits/sec)" axes x1y1, \\
     '${TEMP_DIR}/throughput_data.dat' using 1:3 with lines lc rgb "red" lw 2 title "Cumulative Data (MB)" axes x1y2, \\
     ${THROUGHPUT_MBPS} with lines lc rgb "green" lw 2 dt 2 title "Overall Average (${THROUGHPUT_MBPS} Mbits/sec)" axes x1y1
GNUPLOT_THROUGHPUT
        echo "Throughput graph saved to: ${THROUGHPUT_PNG}"
      fi
    fi
  fi
  # Build time series plot lines
  TIMESERIES_EXTRA=""
  if [ "$SUCCESS_COUNT" -gt 0 ]; then
    TIMESERIES_EXTRA=", \\
     ${AVG_TIME} with lines lc rgb \"green\" lw 2 title \"Average\", \\
     ${P90_TIME} with lines lc rgb \"orange\" lw 2 title \"P90\""
  fi

  # Generate combined summary graph with all relevant plots
  # Create the gnuplot script dynamically
  GNUPLOT_SCRIPT="${TEMP_DIR}/combined_plot.gp"
  
  cat > "$GNUPLOT_SCRIPT" << EOF
set terminal png size 1800,1200 font "Arial,11"
set output '${COMBINED_PNG}'
set multiplot layout 2,3 title "Performance Test Summary - ${LEVEL} Level\\nSuccess: ${SUCCESS_COUNT} | Failures: ${ERROR_COUNT} | Throughput: ${THROUGHPUT_MBPS} Mbits/sec" font "Arial,14"

# Top left: Time series with success/failure
set title "Response Time Over Test Duration"
set xlabel "Request Number"
set ylabel "Response Time (ms)"
set grid
set key top left
plot '${TEMP_DIR}/all_requests.dat' using (\$2==200?\$1:1/0):3 with points pt 7 ps 0.5 lc rgb "blue" title "Success", \\
     '${TEMP_DIR}/all_requests.dat' using (\$2!=200?\$1:1/0):3 with points pt 5 ps 0.8 lc rgb "red" title "Failed"${TIMESERIES_EXTRA}

# Top middle: HTTP Status Code Distribution
set title "HTTP Status Code Distribution"
set xlabel "Status Code"
set ylabel "Count"
set grid ytics
set style fill solid 0.7
set boxwidth 0.7 relative
unset key
set style data histogram
plot '< awk -F"|" "{print \\\$1}" ${RESULTS_FILE} | sort | uniq -c | awk "{print \\\$2, \\\$1}"' using 2:xtic(1) with boxes lc rgb "blue"

# Top right: Throughput over time
EOF

  # Add throughput plot section dynamically
  if [ "$TOTAL_BYTES_SUCCESS" -gt 0 ] && [ -s "${TEMP_DIR}/throughput_data.dat" ]; then
    cat >> "$GNUPLOT_SCRIPT" << EOF
set title "Data Throughput Over Time"
set xlabel "Request Number"
set ylabel "Throughput (Mbits/sec)"
set y2label "Cumulative Data (MB)"
set grid
set key top left
set y2tics
set ytics nomirror
plot '${TEMP_DIR}/throughput_data.dat' using 1:2 with lines lc rgb "blue" lw 2 title "Cumulative Throughput" axes x1y1, \\
     '${TEMP_DIR}/throughput_data.dat' using 1:3 with lines lc rgb "red" lw 2 title "Cumulative Data (MB)" axes x1y2, \\
     ${THROUGHPUT_MBPS} with lines lc rgb "green" lw 2 dt 2 title "Average" axes x1y1
EOF
  else
    cat >> "$GNUPLOT_SCRIPT" << EOF
unset xlabel
unset ylabel
unset border
unset tics
unset key
unset y2tics
unset y2label
set xrange [0:1]
set yrange [0:1]
set title "Throughput Data"
set label 101 "No throughput data\\navailable" at graph 0.5,0.5 center font "Arial,14"
plot -1 notitle
EOF
  fi

  
  # Add bottom left section (statistics)
  cat >> "$GNUPLOT_SCRIPT" << EOF

# Bottom left: Statistics summary (text)
unset xlabel
unset ylabel
unset border
unset tics
unset key
unset y2tics
unset y2label
set xrange [0:1]
set yrange [0:1]
set label 1 "Test Statistics" at screen 0.05, screen 0.45 font "Arial,12"
set label 2 sprintf("Total Requests: %d", ${TOTAL_REQUESTS}) at screen 0.05, screen 0.41
set label 3 sprintf("Success Rate: %.1f%%", (${SUCCESS_COUNT}*100.0/${TOTAL_REQUESTS})) at screen 0.05, screen 0.38
set label 4 sprintf("Failed Requests: %d", ${ERROR_COUNT}) at screen 0.05, screen 0.35
set label 5 sprintf("Duration: %d seconds", ${TOTAL_TIME}) at screen 0.05, screen 0.32
set label 6 sprintf("Request Rate: %.2f req/s", ${TOTAL_REQUESTS}/${TOTAL_TIME}) at screen 0.05, screen 0.29
set label 7 sprintf("Parallel Workers: %d", ${PARALLEL_REQUESTS}) at screen 0.05, screen 0.26
EOF

  # Add response time labels if we have successful requests
  if [ "$SUCCESS_COUNT" -gt 0 ]; then
    cat >> "$GNUPLOT_SCRIPT" << EOF
set label 8 "Response Times" at screen 0.05, screen 0.22 font "Arial,12"
set label 9 sprintf("Min: %d ms", ${MIN_TIME}) at screen 0.05, screen 0.19
set label 10 sprintf("Avg: %d ms", ${AVG_TIME}) at screen 0.05, screen 0.16
set label 11 sprintf("P90: %d ms", ${P90_TIME}) at screen 0.05, screen 0.13
set label 12 sprintf("Max: %d ms", ${MAX_TIME}) at screen 0.05, screen 0.10
EOF
  fi

  # Add throughput labels if we have data
  if [ "$TOTAL_BYTES_SUCCESS" -gt 0 ]; then
    MB_DOWNLOADED=$(echo "scale=2; $TOTAL_BYTES_SUCCESS / 1000000" | bc -l)
    cat >> "$GNUPLOT_SCRIPT" << EOF
set label 13 "Data Transfer" at screen 0.05, screen 0.06 font "Arial,12"
set label 14 sprintf("%.2f MB downloaded", ${MB_DOWNLOADED}) at screen 0.05, screen 0.03
set label 15 sprintf("${THROUGHPUT_MBPS} Mbits/sec") at screen 0.05, screen 0.00
EOF
  fi

  cat >> "$GNUPLOT_SCRIPT" << EOF
plot -1 notitle

# Bottom middle: Response time histogram
EOF

  # Add histogram section dynamically
  if [ "$SUCCESS_COUNT" -gt 10 ] && [ -s "${TEMP_DIR}/success_times.dat" ]; then
    DATA_RANGE=$(awk '{print $2}' "${TEMP_DIR}/success_times.dat" | sort -n | awk 'NR==1{min=$1} {max=$1} END{print max-min}')
    if [ "$DATA_RANGE" -gt 0 ] 2>/dev/null; then
      cat >> "$GNUPLOT_SCRIPT" << EOF
unset label 1
unset label 2
unset label 3
unset label 4
unset label 5
unset label 6
unset label 7
unset label 8
unset label 9
unset label 10
unset label 11
unset label 12
unset label 13
unset label 14
unset label 15
unset label 101
set border
set tics
set title "Response Time Distribution"
set xlabel "Response Time (ms)"
set ylabel "Frequency"
set grid ytics
set style fill solid 0.5
set boxwidth 0.9 relative
unset key
stats '${TEMP_DIR}/success_times.dat' using 2 nooutput
binwidth = (STATS_max - STATS_min) / 20
if (binwidth <= 0) binwidth = 1
bin(x,width)=width*floor(x/width)
plot '${TEMP_DIR}/success_times.dat' using (bin(\$2,binwidth)):(1.0) smooth freq with boxes lc rgb "blue"
EOF
    else
      cat >> "$GNUPLOT_SCRIPT" << EOF
unset label 1
unset label 2
unset label 3
unset label 4
unset label 5
unset label 6
unset label 7
unset label 8
unset label 9
unset label 10
unset label 11
unset label 12
unset label 13
unset label 14
unset label 15
unset label 101
set border
set tics
set title "Response Time Distribution"
set xlabel ""
set ylabel ""
unset grid
unset key
set label 102 "All response times\\nidentical (${AVG_TIME}ms)" at graph 0.5, 0.5 center font "Arial,12"
plot -1 notitle
EOF
    fi
  else
    cat >> "$GNUPLOT_SCRIPT" << EOF
unset label 1
unset label 2
unset label 3
unset label 4
unset label 5
unset label 6
unset label 7
unset label 8
unset label 9
unset label 10
unset label 11
unset label 12
unset label 13
unset label 14
unset label 15
unset label 101
set border
set tics
set title "Response Time Distribution"
set xlabel ""
set ylabel ""
unset grid
unset key
set label 102 "Not enough successful\\nrequests for distribution" at graph 0.5, 0.5 center font "Arial,12"
plot -1 notitle
EOF
  fi

  # Add error summary section
  cat >> "$GNUPLOT_SCRIPT" << EOF

# Bottom right: Error breakdown
unset label 1
unset label 2
unset label 3
unset label 4
unset label 5
unset label 6
unset label 7
unset label 8
unset label 9
unset label 10
unset label 11
unset label 12
unset label 13
unset label 14
unset label 15
unset label 101
unset label 102
unset border
unset tics
set title "Error Summary"
set xlabel ""
set ylabel ""
unset grid
unset key
set xrange [0:1]
set yrange [0:1]
EOF

  # Add error labels dynamically
  if [ "$ERROR_COUNT" -gt 0 ]; then
    echo 'set label 200 "Error Breakdown" at graph 0.1, 0.9 font "Arial,12"' >> "$GNUPLOT_SCRIPT"
    grep -v "^200|" "$RESULTS_FILE" | cut -d'|' -f1 | sort | uniq -c | head -5 | awk '{
      y_pos = 0.8 - (NR * 0.1)
      printf "set label %d \"HTTP %s: %d errors\" at graph 0.1, %.2f font \"Arial,11\"\n", 200 + NR, $2, $1, y_pos
    }' >> "$GNUPLOT_SCRIPT"
  else
    echo 'set label 200 "No Errors" at graph 0.5, 0.5 center font "Arial,14" tc rgb "green"' >> "$GNUPLOT_SCRIPT"
  fi

  cat >> "$GNUPLOT_SCRIPT" << EOF
plot -1 notitle
unset multiplot
EOF

  # Execute the gnuplot script
  gnuplot "$GNUPLOT_SCRIPT" 2>/dev/null
  
  echo "Combined summary saved to: ${COMBINED_PNG}"
  echo ""
  echo "All graphs generated successfully!"
fi

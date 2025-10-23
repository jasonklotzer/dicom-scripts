# DICOM Store Scripts

This directory contains bash scripts that facilitate importing and testing DICOM files with a DICOM store using the Google Cloud Healthcare API.

## Scripts

### Insert Scripts

* `insert_file.sh`: Inserts a single DICOM file into a DICOM store.
* `insert_folder.sh`: Inserts all DICOM files within a specified folder into a DICOM store.
* `post.sh`: This is a helper script that performs the actual HTTP POST request to the DICOMweb service.

### Retrieve Scripts

* `perf_test.sh`: Performance testing tool for DICOMweb retrievals. Tests retrieval performance at study, series, instance, or frame levels with configurable parallelism and duration.

## Prerequisites

*   A Google Cloud project with the Healthcare API enabled.
*   Authentication configured for accessing the Healthcare API (e.g., using a service account).
*   The `gcloud` command-line tool installed and configured.
*   DICOM files that you want to import.
*   For performance testing: `bc` (basic calculator) command-line tool.
*   For graph generation (optional): `gnuplot` package.

## Usage

### Insert Operations

#### `insert_file.sh`

```bash
./insert/insert_file.sh <dicomStorePath> <dcmFilePath>
```

Inserts a single DICOM file into the specified DICOM store.

**Example:**
```bash
./insert/insert_file.sh projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store /path/to/file.dcm
```

### Retrieve Operations

#### `perf_test.sh`

Performance testing tool for measuring DICOMweb retrieval throughput and latency.

**Usage:**
```bash
./retrieve/perf_test.sh -f <pathsFile> [options]
```

**Required Arguments:**
* `-f <pathsFile>` - File containing a list of DICOMweb paths (one per line). The level (study/series/instance/frame) is auto-detected from the path structure. Workers will cycle through the list, allowing you to test multiple paths or repeatedly access the same paths.

**Performance Options:**
* `-p <number>` - Number of parallel requests (default: 10)
* `-n <number>` - Total number of requests to send (unlimited by default, requires `-d` if not specified)
* `-d <seconds>` - Duration to run the test in seconds (unlimited by default, requires `-n` if not specified)
* `-t <seconds>` - Per-request timeout in seconds (default: 20)
* `-r <number>` - Maximum number of retries for HTTP 429 errors (default: 3, set to 0 to disable)
* `-R` - Randomize the order of paths from the input file (default: sequential)
* `-o <directory>` - Output directory to save results and graphs (default: ./output)
* `-g` - Generate graphs (requires gnuplot to be installed)
* `-v` - Verbose mode - shows individual request results with path indices
* `-h` - Show help message

**Supported Levels:**
The script automatically detects the DICOM hierarchy level based on the path:
* **Study level**: `.../dicomWeb/studies/{studyUID}`
* **Series level**: `.../dicomWeb/studies/{studyUID}/series/{seriesUID}`
* **Instance level**: `.../dicomWeb/studies/{studyUID}/series/{seriesUID}/instances/{instanceUID}`
* **Frame level**: `.../dicomWeb/studies/{studyUID}/series/{seriesUID}/instances/{instanceUID}/frames/{frameNumber}`

**Output Statistics:**
* Total requests and duration
* Throughput (requests/second)
* Success rate and error breakdown
* Response time metrics: Min, Max, Average, Median, P90
* Retry statistics (how many requests needed retries)
* Errors by path index (showing which specific paths from your input file are failing)
* CSV and text file output saved to the output directory with columns: `request_num`, `http_code`, `response_time_ms`, `retries`, `path_index`
* Optional graph generation (PNG format):
  - Response time histogram
  - Time series plot
  - HTTP status code distribution
  - Combined summary dashboard

**Examples:**

Create a file with instance paths (one per line):
```bash
# instances.txt
projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb/studies/1.2.3/series/4.5.6/instances/7.8.9
projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb/studies/1.2.3/series/4.5.6/instances/7.8.10
# ... more paths
```

Test with instance list - sequential access (simulates repeated access to same files):
```bash
./retrieve/perf_test.sh -f instances.txt -n 1000 -p 10
```

Test with instance list - randomized access:
```bash
./retrieve/perf_test.sh -f instances.txt -n 1000 -p 10 -R
```

Test for a specific duration with verbose output:
```bash
./retrieve/perf_test.sh -f instances.txt -d 60 -p 5 -v
```

Test with graph generation and custom output directory:
```bash
./retrieve/perf_test.sh -f instances.txt -n 1000 -p 10 -o ./my-results -g
```

Generate instance list using `get_instance_list.sh`:
```bash
# First, generate a list of all instances in a DICOM store
./retrieve/get_instance_list.sh \
  projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb \
  --output instances.txt

# Then run performance test
./retrieve/perf_test.sh -f instances.txt -n 5000 -p 20 -g
```

**Notes:**
* You must specify either `-n` (max requests), `-d` (duration), or both
* The paths file can contain full URLs or short paths (e.g., `projects/...`). Short paths will be automatically prefixed with `https://healthcare.googleapis.com/v1/`
* Workers cycle through the paths file, so with 10 workers and 100 paths, each worker will rotate through different paths
* Without `-R`, paths are accessed sequentially, allowing you to test repeated access to the same files
* With `-R`, paths are randomized once at startup, then workers cycle through the randomized list
* The CSV output includes a `path_index` column (0-based) that maps back to the line number in your input file
* Error breakdown includes "Errors by Path Index" showing which specific files are failing
* The script uses `gcloud auth application-default print-access-token` for authentication
* Results are saved as CSV and text files with timestamp in the output directory
* HTTP 429 (Too Many Requests) errors are automatically retried with exponential backoff (1s, 2s, 4s, etc.)
* Graph generation requires `gnuplot` to be installed (install with `apt-get install gnuplot` or `brew install gnuplot`)
* HTTP 200 responses are considered successful; all others are tracked as errors
* The output directory will be created if it doesn't exist

#### `get_instance_list.sh`

Utility to generate a list of all instance paths in a DICOM store by querying the DICOMweb QIDO-RS endpoints.

**Usage:**
```bash
./retrieve/get_instance_list.sh <DICOM_WEB_BASE> [--frames] [--output FILE]
```

**Arguments:**
* `<DICOM_WEB_BASE>` - Base DICOMweb path (e.g., `projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb`)
* `--frames` - Append `/frames/1` to each instance path
* `--output FILE` - Write results to FILE (default: stdout)

**Example:**
```bash
./retrieve/get_instance_list.sh \
  projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb \
  --output instances.txt
```

The script will query all studies, series, and instances, showing progress as it runs
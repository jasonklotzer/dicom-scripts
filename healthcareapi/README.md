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
./retrieve/perf_test.sh -w <dicomwebPath> [options]
```

**Required Arguments:**
* `-w <dicomwebPath>` - Full DICOMweb path to test. The level (study/series/instance/frame) is auto-detected from the path structure.

**Performance Options:**
* `-p <number>` - Number of parallel requests (default: 10)
* `-n <number>` - Total number of requests to send (unlimited by default, requires `-d` if not specified)
* `-d <seconds>` - Duration to run the test in seconds (unlimited by default, requires `-n` if not specified)
* `-t <seconds>` - Per-request timeout in seconds (default: 20)
* `-o <directory>` - Output directory to save results and graphs (default: ./output)
* `-g` - Generate graphs (requires gnuplot to be installed)
* `-v` - Verbose mode - shows individual request results
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
* CSV and text file output saved to the output directory
* Optional graph generation (PNG format):
  - Response time histogram
  - Time series plot
  - HTTP status code distribution
  - Combined summary dashboard

**Examples:**

Test study-level retrieval with 100 requests using 10 parallel workers:
```bash
./retrieve/perf_test.sh \
  -w "projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb/studies/1.2.840.113619.2.55.3.4.1" \
  -n 100 -p 10
```

Test series-level retrieval for 60 seconds with 5 parallel workers:
```bash
./retrieve/perf_test.sh \
  -w "projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb/studies/1.2.840.113619.2.55.3.4.1/series/1.2.840.113619.2.55.3.5.1" \
  -d 60 -p 5
```

Test instance-level retrieval with 200 requests over 120 seconds with 15 parallel workers:
```bash
./retrieve/perf_test.sh \
  -w "projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb/studies/1.2.840.113619.2.55.3.4.1/series/1.2.840.113619.2.55.3.5.1/instances/1.2.840.113619.2.55.3.6.1" \
  -n 200 -d 120 -p 15
```

Test frame-level retrieval (frame 1) with verbose output:
```bash
./retrieve/perf_test.sh \
  -w "projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb/studies/1.2.840.113619.2.55.3.4.1/series/1.2.840.113619.2.55.3.5.1/instances/1.2.840.113619.2.55.3.6.1/frames/1" \
  -n 500 -p 20 -v
```

Test with graph generation and custom output directory:
```bash
./retrieve/perf_test.sh \
  -w "projects/my-project/locations/us-central1/datasets/my-dataset/dicomStores/my-store/dicomWeb/studies/1.2.840.113619.2.55.3.4.1" \
  -n 1000 -p 10 -o ./my-results -g
```

**Notes:**
* You must specify either `-n` (max requests), `-d` (duration), or both
* The script uses `gcloud auth application-default print-access-token` for authentication
* Results are saved as CSV and text files with timestamp in the output directory
* Graph generation requires `gnuplot` to be installed (install with `apt-get install gnuplot` or `brew install gnuplot`)
* HTTP 200 responses are considered successful; all others are tracked as errors
* The output directory will be created if it doesn't exist
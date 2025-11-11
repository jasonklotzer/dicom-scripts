# DICOM Helper Scripts

This repository contains a collection of bash scripts designed to streamline various tasks related to handling and processing DICOM (Digital Imaging and Communications in Medicine) data. Some scripts leverage Google Cloud services, such as the Healthcare API for interacting with DICOM stores.

## Scripts

### General DICOM Utilities

* **`ccli.sh`:** Provides a convenient command-line interface for executing common DICOM utilities within a Docker container. Supports both `dcmtk` and `dcm4che` toolsets.

### Study Creation Tools

* **`create_study/makestudy.sh`:** Generates a series of DICOM files with varying study and instance numbers, useful for testing and populating DICOM stores.

* **`create_study/gen_study/gen_study.py`:** Python script for generating DICOM study data with configurable parameters.

### DIMSE Operations

* **`dimse/findstudies.sh`:** Search a PACS and create a JSON file with metadata for all the responses

### Google Cloud Healthcare API Integration

#### De-identification
* **`healthcareapi/deid/deid_dicom_store.sh`:** De-identify a set of DICOM files in a DICOM store using Google Cloud Healthcare API

#### Data Insertion
* **`healthcareapi/insert/insert_file.sh`:** Uploads a single DICOM file to a specified DICOM store using the Healthcare API v1beta1 endpoint via PUT method. Includes comprehensive help documentation accessible with `--help`.

* **`healthcareapi/insert/insert_folder.sh`:** Uploads all DICOM files within a given folder to a DICOM store using the Healthcare API v1 endpoint via POST method. Supports parallel processing, selective study deletion, and single-study mode. Includes comprehensive help documentation accessible with `--help`.

* **`healthcareapi/insert/post.sh`:** A helper script that handles HTTP POST requests for DICOMweb interactions using the Healthcare API v1 endpoint. Constructs its own API endpoint and handles rate limiting with automatic retries.

* **`healthcareapi/insert/put.sh`:** A helper script that handles HTTP PUT requests for DICOMweb interactions using the Healthcare API v1beta1 endpoint. Constructs its own API endpoint and handles rate limiting with automatic retries.

#### Data Retrieval
* **`healthcareapi/retrieve/get_instance_list.sh`:** Retrieve a list of DICOM instances from a Healthcare API DICOM store

* **`healthcareapi/retrieve/perf_test.sh`:** Performance testing script for Healthcare API operations with detailed metrics and output logging

## Prerequisites

* **General:**
    * Bash shell
    * Docker (for `ccli.sh`)
    * `dcmodify` (for `create_study/makestudy.sh`)
    * Python 3 with required packages (for `create_study/gen_study/gen_study.py`)
    * `findscu` and `dcm2json` (for `dimse/findstudies.sh`)

* **Healthcare API Scripts:**
    * Google Cloud Project with Healthcare API enabled
    * Service account with appropriate permissions
    * `gcloud` command-line tool
    * `curl` and `jq` (for JSON processing)
    * `dcm2bq` (for `healthcareapi/insert/insert_folder.sh`)

## Usage

### Getting Help

Most scripts include built-in help documentation. Use the `--help` flag for detailed usage information:

```bash
# Get help for Healthcare API scripts
./healthcareapi/insert/insert_file.sh --help
./healthcareapi/insert/insert_folder.sh --help
```

### Healthcare API Scripts

**Single File Upload:**
```bash
./healthcareapi/insert/insert_file.sh \
  projects/PROJECT_ID/locations/LOCATION/datasets/DATASET_ID/dicomStores/DICOM_STORE_ID \
  path/to/file.dcm
```

**Folder Upload (Basic):**
```bash
./healthcareapi/insert/insert_folder.sh \
  projects/PROJECT_ID/locations/LOCATION/datasets/DATASET_ID/dicomStores/DICOM_STORE_ID \
  /path/to/dicom/folder
```

**Folder Upload (Advanced Options):**
```bash
# Single study, skip deletion, 20 parallel processes
./healthcareapi/insert/insert_folder.sh -s -d -p 20 \
  projects/PROJECT_ID/locations/LOCATION/datasets/DATASET_ID/dicomStores/DICOM_STORE_ID \
  /path/to/dicom/folder
```

Refer to the individual script files and their `--help` output for detailed usage instructions and examples.

## Contributing

Contributions are welcome! Feel free to submit pull requests for bug fixes, new features, or improvements to existing scripts.

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
# DICOM Store Import Scripts

This directory contains bash scripts that facilitate importing DICOM files into a DICOM store using the Google Cloud Healthcare API.

## Scripts

* `insert_file.sh`: Inserts a single DICOM file into a DICOM store.
* `insert_folder.sh`: Inserts all DICOM files within a specified folder into a DICOM store.
* `post.sh`: This is a helper script that performs the actual HTTP POST request to the DICOMweb service.

## Prerequisites

*   A Google Cloud project with the Healthcare API enabled.
*   Authentication configured for accessing the Healthcare API (e.g., using a service account).
*   The `gcloud` command-line tool installed and configured.
*   DICOM files that you want to import.

## Usage

### `insert_file.sh`

```bash
./insert_file.sh <dicomStorePath> <dcmFilePath>
```
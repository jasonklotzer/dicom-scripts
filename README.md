# DICOM Helper Scripts

This repository contains a collection of bash scripts designed to streamline various tasks related to handling and processing DICOM (Digital Imaging and Communications in Medicine) data. Some scripts leverage Google Cloud services, such as the Healthcare API for interacting with DICOM stores.

## Scripts

### General DICOM Utilities

* **`ccli.sh`:** Provides a convenient command-line interface for executing common DICOM utilities within a Docker container. Supports both `dcmtk` and `dcm4che` toolsets.

* **`makestudy.sh`:** Generates a series of DICOM files with varying study and instance numbers, useful for testing and populating DICOM stores.

### Google Cloud Healthcare API Integration

* **`healthcareapi/insert/insert_file.sh`:** Uploads a single DICOM file to a specified DICOM store using the Healthcare API.

* **`healthcareapi/insert/insert_folder.sh`:** Uploads all DICOM files within a given folder to a DICOM store.

* **`healthcareapi/insert/post.sh`:** A helper script that handles the HTTP POST requests for DICOMweb interactions.

## Prerequisites

* **General:**
    * Bash shell
    * Docker (for `ccli.sh`)
    * `dcmodify` (for `makestudy.sh`)

* **Healthcare API Scripts:**
    * Google Cloud Project with Healthcare API enabled
    * Service account with appropriate permissions
    * `gcloud` command-line tool
    * `curl` and `jq` (for JSON processing)

## Usage

Refer to the individual script files for detailed usage instructions and examples.

## Contributing

Contributions are welcome! Feel free to submit pull requests for bug fixes, new features, or improvements to existing scripts.

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
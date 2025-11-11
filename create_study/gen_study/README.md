# DICOM Study Generator (`gen_study.py`)

This Python script, `gen_study.py`, generates synthetic DICOM studies with configurable parameters. It creates a directory for each study containing a set of DICOM image objects and a Structured Report (SR) object.

## Features

*   **Configurable Modalities:** Supports generating studies for various imaging modalities, including CT, MR, XA, CR, and US.
*   **Plausible Pixel Data:** Can generate fake, yet plausible, pixel data for image objects, simulating characteristics of different modalities.
*   **Structured Reports:** Creates an SR object containing a randomly generated report text related to the study.
*   **Metadata Overrides:** Allows overriding default DICOM tag values using command-line arguments.
*   **Body Part Jumbling:** Optionally vary the `BodyPartExamined` tag across instances within a series, simulating slight variations in patient positioning or acquisition.
*   **Customizable Output:** Control the base output directory for generated studies.
*   **Quiet Mode:** Suppress informational output during script execution for cleaner runs.

## Requirements

*   Python 3.6 or higher
*   `pydicom` library
*   `faker` library
*   `numpy` library
*   (Optional) `scipy` library (for pixel data smoothing)

You can install the required libraries using `pip`:

```bash
pip install pydicom faker numpy scipy
```

## Usage

```bash
python gen_study.py [options]
```

### Options and Parameters

*   `--set TAG_KEYWORD VALUE`: Override a specific DICOM tag. Use pydicom keyword (e.g., `PatientID`, `PatientName`, `StudyDescription`, `BodyPartExamined`). Can be used multiple times to override multiple tags.
    *   Example: `python gen_study.py --set PatientName "Doe^John" --set PatientID "1234567890"`
*   `--generate-pixels`: Enable generation of plausible fake pixel data for image objects. If omitted, pixel data will be zero bytes.
    *   Example: `python gen_study.py --generate-pixels`
*   `--base-dir DIRECTORY`: Specify the base directory to create study subdirectories in. Defaults to `dicom_studies_output`.
    *   Example: `python gen_study.py --base-dir /path/to/my/output`
*   `--quiet`, `-q`: Suppress informational print statements during execution. Errors will still be displayed.
    *   Example: `python gen_study.py -q`
*   `--jumble-body-part`: If set, the `BodyPartExamined` tag will vary (plausibly) for each instance within the series. Otherwise, it will be consistent across the series.
    *   Example: `python gen_study.py --jumble-body-part`

### Examples

1.  Generate a study with default settings (CT modality, no pixel data, consistent `BodyPartExamined`):

    ```bash
    python gen_study.py
    ```

2.  Generate an MR study with pixel data, overriding the patient name and jumbling the `BodyPartExamined`:

    ```bash
    python gen_study.py --set Modality "MR" --generate-pixels --set PatientName "Smith^Jane" --jumble-body-part
    ```
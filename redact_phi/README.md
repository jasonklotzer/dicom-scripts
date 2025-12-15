# DICOM PHI Text Extraction and Redaction

A robust, local-only tool for extracting and redacting burned-in text from DICOM images using **PaddleOCR**.

## Overview

This tool processes DICOM files to:
1. **Extract** all burned-in text (PHI) using the high-accuracy PaddleOCR engine.
2. **Redact** detected text regions by filling them with neutral pixel values.
3. **Output** verification images (pre/post) and extracted text.

It is designed to handle complex edge cases often found in medical imaging:
*   **Color DICOMs** (Ultrasound, Secondary Capture)
*   **High Bit-Depth** (16-bit X-Ray/CT/MRI)
*   **"Hidden" PHI** (Low contrast text outside the standard clinical window)

## Key Insight: The "Enhanced Stretched" Pipeline

Standard OCR often fails on medical images because clinical "Window/Level" settings can hide text, or 16-bit pixel data is improperly downscaled.

This tool uses a specialized preprocessing pipeline for detection:

1.  **Normalization**: Converts 16-bit or Color data to 8-bit Grayscale using the *full dynamic range* (ignoring clinical windowing that might hide text).
2.  **CLAHE**: Applies Contrast Limited Adaptive Histogram Equalization to normalize local contrast.
3.  **Contrast Stretching**: Linearly stretches the pixel intensity histogram to the full 0-255 range.

**Result:** Text that is barely visible to the human eye (or hidden in dark/bright regions) becomes high-contrast and detectable by OCR.

## Installation

```bash
cd redact_phi
./install.sh
```

This will:
- Create a Python virtual environment (`.venv`)
- Install Python dependencies (`paddleocr`, `opencv-python`, `pydicom`, etc.)

## Usage

### Command Line

```bash
source .venv/bin/activate
python redact_phi.py \
  --input <dicom_file> \
  --out-pre <pre_redaction_png> \
  --out-post <post_redaction_png> \
  --out-text <extracted_text_file>
```

### Example

```bash
python redact_phi.py \
  --input test/files/color_8bit.dcm \
  --out-pre out/color_pre.png \
  --out-post out/color_post.png \
  --out-text out/color_text.txt
```

### Automated Testing

To run the tool against a suite of synthetic test cases (Color, 16-bit, Hidden PHI):

```bash
./test_redact_phi.sh
```

## How It Works

### 1. Intelligent Loading
- **Color**: Detects `SamplesPerPixel > 1`. Converts to Grayscale for OCR, but redacts on the original Color image.
- **16-bit**: Detects `BitsStored > 8`. Converts to 8-bit using min/max scaling to preserve all data, ignoring potentially misleading Window/Level tags.

### 2. Detection Pipeline
The image goes through the "Enhanced Stretched" pipeline described above. PaddleOCR (Server model) runs on this high-contrast version to find text bounding boxes.

### 3. Redaction
- Maps the bounding boxes from the detection image back to the original image coordinate space.
- Fills the regions with the **median color** of the ROI (Region of Interest) to create a clean, neutral redaction.
- Adds padding (default 10px) to ensure full coverage.

## Output Files

*   **`pre_redaction.png`**: The image used for OCR detection (Enhanced/Stretched). Use this to verify if the text was visible to the engine.
*   **`post_redaction.png`**: The final result. The original image (Color or Grayscale) with text boxes filled in.
*   **`extracted_text.txt`**: Raw text content found in the image.

## Features & Capabilities

| Feature | Support | Notes |
| :--- | :--- | :--- |
| **OCR Engine** | PaddleOCR v2.7+ | High accuracy, supports rotation better than Tesseract. |
| **Color DICOM** | ✅ Yes | Redacts on RGB, detects on Gray. |
| **16-bit DICOM** | ✅ Yes | Auto-scales to 8-bit for detection. |
| **Hidden PHI** | ✅ Yes | CLAHE + Contrast Stretching reveals low-contrast text. |
| **Multiframe** | ⚠️ Partial | Currently processes the **first frame** only. |

## Limitations

1.  **Multiframe Support**: Currently only processes the first frame of a multiframe DICOM.
2.  **Complex Backgrounds**: Text over highly textured anatomical backgrounds may occasionally be missed or have false positives.
3.  **Overlapping Text**: Redaction is a simple box fill; it does not attempt to "inpainting" or reconstruct the background anatomy.

## License

See LICENSE file in parent directory.

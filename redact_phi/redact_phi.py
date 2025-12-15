#!/usr/bin/env python3
"""
DICOM text extraction and redaction using PaddleOCR.
Reads DICOM file, applies CLAHE normalization, and extracts text using PaddleOCR.
"""

import argparse
import os
import cv2
import numpy as np
import paddle
import pydicom
from pydicom.pixels import apply_voi_lut
from paddleocr import PaddleOCR


def extract_text_from_dicom(dicom_path, transform_mode='clahe'):
    """
    Read DICOM file, apply CLAHE normalization to 8-bit, and extract text using PaddleOCR.
    Also returns detected text coordinates for redaction.
    
    Args:
        dicom_path: Path to DICOM file
        
    Returns:
        Tuple of (extracted_text, 8bit_image, detection_results)
    """
    # 1. Read DICOM file
    print(f"Reading DICOM: {dicom_path}")
    ds = pydicom.dcmread(dicom_path)
    pixel_array = ds.pixel_array.copy()
    
    # Prepare image for output (redaction target)
    image_for_output = None

    # Handle Multiframe and Color images
    samples_per_pixel = ds.get('SamplesPerPixel', 1)
    print(f"SamplesPerPixel: {samples_per_pixel}")

    if samples_per_pixel > 1:
        # Color image
        if pixel_array.ndim > 3:
            print("Multiframe Color DICOM detected. Using first frame.")
            pixel_array = pixel_array[0]
        
        # Capture output image (BGR for OpenCV)
        if pixel_array.shape[-1] == 3:
            image_for_output = cv2.cvtColor(pixel_array, cv2.COLOR_RGB2BGR)
        elif pixel_array.shape[-1] == 4:
            image_for_output = cv2.cvtColor(pixel_array, cv2.COLOR_RGBA2BGR)

        # Convert to grayscale for processing
        print("Converting color image to grayscale...")
        if pixel_array.shape[-1] == 3:
            pixel_array = cv2.cvtColor(pixel_array, cv2.COLOR_RGB2GRAY)
        elif pixel_array.shape[-1] == 4:
            pixel_array = cv2.cvtColor(pixel_array, cv2.COLOR_RGBA2GRAY)
            
    elif pixel_array.ndim > 2:
        # Multiframe Grayscale
        print("Multiframe Grayscale DICOM detected. Using first frame.")
        pixel_array = pixel_array[0]
    
    print(f"Pixel array shape: {pixel_array.shape}, dtype: {pixel_array.dtype}")
    print(f"Pixel range: {pixel_array.min()} to {pixel_array.max()}")
    
    enhanced_stretched = None
    image_8bit = None

    if transform_mode == 'standard':
        print("Using Standard DICOM Window/Level...")
        # 1) Apply Modality LUT / Rescale Slope-Intercept via apply_voi_lut (grayscale only)
        if samples_per_pixel == 1:
            try:
                pixel_array = apply_voi_lut(pixel_array, ds)
                print(f"VOI LUT applied (includes Rescale Slope/Intercept). Range: {pixel_array.min()} to {pixel_array.max()}")
            except Exception as e:
                print(f"VOI LUT application skipped: {e}")
        else:
            print("Skipping VOI LUT for color image")

        # 2) Apply Window/Level from metadata to presentation values
        window_center = ds.get('WindowCenter')
        window_width = ds.get('WindowWidth')
        if isinstance(window_center, (list, tuple, pydicom.multival.MultiValue)):
            window_center = window_center[0]
        if isinstance(window_width, (list, tuple, pydicom.multival.MultiValue)):
            window_width = window_width[0]

        # Fallback if tags missing: use min/max-based window
        if window_center is None or window_width is None:
            min_val = float(np.min(pixel_array))
            max_val = float(np.max(pixel_array))
            window_center = (min_val + max_val) / 2.0
            window_width = (max_val - min_val) if max_val > min_val else 1.0
            print(f"Window tags missing; using data-derived window center={window_center}, width={window_width}")
        else:
            window_center = float(window_center)
            window_width = float(window_width)

        lower = window_center - (window_width / 2)
        upper = window_center + (window_width / 2)
        windowed = np.clip(pixel_array, lower, upper)

        # 3) Normalize windowed image to 0-255 for rendering/OCR
        image_8bit = ((windowed - lower) / (upper - lower) * 255.0).astype(np.uint8)

        # Handle PhotometricInterpretation (MONOCHROME1)
        if ds.get('PhotometricInterpretation') == 'MONOCHROME1':
            image_8bit = cv2.bitwise_not(image_8bit)
            
        if image_for_output is None:
            image_for_output = image_8bit
            
        # For standard mode, we use the windowed image for detection
        enhanced_stretched = image_8bit

    else:
        # Default: CLAHE / Enhanced Stretched Pipeline
        
        # 2. Convert higher bit depths to 8-bit while preserving full dynamic range
        # This ensures no PHI is hidden in value extremes
        if pixel_array.dtype != np.uint8:
            print(f"Converting from {pixel_array.dtype} to uint8 (preserving full dynamic range)...")
            min_val = pixel_array.min()
            max_val = pixel_array.max()
            if max_val > min_val:
                pixel_array = ((pixel_array - min_val) / (max_val - min_val) * 255.0).astype(np.uint8)
            else:
                pixel_array = pixel_array.astype(np.uint8)
            print(f"Converted range: {pixel_array.min()} to {pixel_array.max()}")
        
        # 3. Apply CLAHE to normalize the entire pixel range
        # This makes burned-in text (which may be outside the Window/Level range) visible
        clahe = cv2.createCLAHE(clipLimit=4.0, tileGridSize=(8, 8))
        clahe_applied = clahe.apply(pixel_array)
        
        print(f"CLAHE applied - range: {clahe_applied.min()} to {clahe_applied.max()}")
        
        # 4. Apply Window/Level on the CLAHE-enhanced image for proper visualization
        # Note: For 16-bit images converted to 8-bit, the original Window/Level values 
        # (which are in 16-bit space) are no longer valid for the 8-bit image.
        # We should either scale the W/L or re-calculate optimal W/L for the 8-bit image.
        
        # If we converted from >8bit, the original W/L is likely in the original range
        original_bits_stored = ds.get('BitsStored', 8)
        
        window_center = ds.get('WindowCenter')
        window_width = ds.get('WindowWidth')
        
        # Handle multi-value Window Center/Width (take first)
        if isinstance(window_center, (list, tuple, pydicom.multival.MultiValue)):
            window_center = window_center[0]
        if isinstance(window_width, (list, tuple, pydicom.multival.MultiValue)):
            window_width = window_width[0]
            
        if window_center is None or window_width is None:
            # Default to full range if not specified
            window_center = 128
            window_width = 256
        else:
            window_center = float(window_center)
            window_width = float(window_width)
            
            # If original was > 8 bit, we need to scale the W/L to our new 8-bit range
            # The pixel_array was scaled by (val - min) / (max - min) * 255
            if original_bits_stored > 8:
                 # We need the original min/max to scale the W/L correctly
                 # But we don't have them here easily without re-reading or passing them down.
                 # HOWEVER, since we applied CLAHE to the full 8-bit range (0-255), 
                 # the histogram is already equalized. 
                 # Applying the original (scaled) W/L might be incorrect because CLAHE changed the distribution.
                 
                 # Strategy: Since CLAHE already normalized the contrast locally, 
                 # we might not strictly NEED the original Window/Level for text detection.
                 # In fact, applying a specific W/L *after* CLAHE might hide things again.
                 # Let's try using a full-range window for the "normalized" image 
                 # when we've done significant bit-depth conversion.
                 
                 print(f"Original W/L ({window_center}/{window_width}) is for {original_bits_stored}-bit data.")
                 print("Using full 8-bit range for normalized image due to bit-depth conversion.")
                 window_center = 128
                 window_width = 256

        lower = window_center - (window_width / 2)
        upper = window_center + (window_width / 2)
        
        print(f"Window/Level: center={window_center}, width={window_width}")
        print(f"Window range: {lower} to {upper}")
        
        # Apply window/level to CLAHE image
        windowed = np.clip(clahe_applied, lower, upper)
        normalized = ((windowed - lower) / (upper - lower) * 255.0).astype(np.uint8)
        
        # Handle PhotometricInterpretation
        if ds.get('PhotometricInterpretation') == 'MONOCHROME1':
            normalized = cv2.bitwise_not(normalized)
        
        print(f"Final 8-bit range: {normalized.min()} to {normalized.max()}")
        
        if image_for_output is None:
            # If it wasn't color, use the normalized (Window/Level) grayscale image for output
            image_for_output = normalized
            image_8bit = normalized
        else:
            image_8bit = normalized

        # 5. Apply CLAHE for additional local contrast enhancement (moderate)
        clahe2 = cv2.createCLAHE(clipLimit=4.0, tileGridSize=(8, 8))
        enhanced = clahe2.apply(normalized)
        print(f"Second CLAHE pass range: {enhanced.min()} to {enhanced.max()}")

        # 5b. Additional contrast stretch for OCR
        min_val = enhanced.min()
        max_val = enhanced.max()
        if max_val > min_val:
            enhanced_stretched = ((enhanced - min_val) / (max_val - min_val) * 255.0).astype(np.uint8)
        else:
            enhanced_stretched = enhanced
    print(f"Stretched range: {enhanced_stretched.min()} to {enhanced_stretched.max()}")

    # 6. Extract text using PaddleOCR
    print("\nInitializing PaddleOCR...")

    # Prefer GPU when available; fall back to CPU if CUDA is missing or no device is present.
    compiled_with_cuda = False
    gpu_count = 0
    use_gpu = False
    try:
        compiled_with_cuda = paddle.device.is_compiled_with_cuda()
        if compiled_with_cuda:
            try:
                gpu_count = paddle.device.cuda.device_count()
            except Exception:
                gpu_count = 0
        use_gpu = compiled_with_cuda and gpu_count > 0
    except Exception as e:
        print(f"Paddle GPU capability check failed: {e}")
        use_gpu = False

    # Set device globally for Paddle (avoids unsupported args on PaddleOCR)
    try:
        paddle.set_device('gpu' if use_gpu else 'cpu')
    except Exception as e:
        print(f"Failed to set device to {'gpu' if use_gpu else 'cpu'}: {e}. Falling back to CPU.")
        try:
            paddle.set_device('cpu')
            use_gpu = False
        except Exception as e_cpu:
            print(f"Failed to set device to CPU: {e_cpu}")

    ocr = PaddleOCR(
        use_textline_orientation=False, 
        lang='en', 
        use_doc_orientation_classify=False,
        use_doc_unwarping=False
    )

    # Debug: report whether Paddle is using GPU
    try:
        place = paddle.device.get_device()
        print(
            f"Paddle device: {place} "
            f"(paddle compiled with CUDA: {compiled_with_cuda}, gpu_count: {gpu_count}, use_gpu={use_gpu})"
        )
    except Exception as e:
        print(f"Paddle GPU check failed: {e}")

    print(f"\nDetecting text on enhanced_stretched variant")
    bgr = cv2.cvtColor(enhanced_stretched, cv2.COLOR_GRAY2BGR)
    results = ocr.predict(bgr)
    primary_detections = _parse_ocr_results(results)
    
    all_text = []
    if primary_detections:
        print(f"  Detected {len(primary_detections)} regions")
        for i, (bbox, text, conf) in enumerate(primary_detections):
            print(f"    [{i}] '{text}' (conf={conf:.3f}) bbox={bbox}")
            if text.strip():
                all_text.append(text)
    else:
        print("  No detections found")

    extracted_text = ' '.join(all_text) if all_text else "(No text detected)"
    print(f"\nExtracted text:\n{extracted_text}\n")

    # Return the first successful results set (fall back to empty)
    return extracted_text, image_for_output, primary_detections


def _parse_ocr_results(results):
    """Normalize PaddleOCR results into (bbox, text, score) tuples."""
    detections = []
    if not results:
        return detections

    # PaddleOCR returns a list per image
    per_image = results[0] if isinstance(results[0], (list, tuple, dict)) else results

    # Dict-style result (newer PaddleOCR with doc pipeline off)
    if isinstance(per_image, dict):
        texts = per_image.get('rec_texts') or []
        scores = per_image.get('rec_scores') or []
        polys = per_image.get('rec_polys') or []
        boxes = per_image.get('rec_boxes')

        for idx, text in enumerate(texts):
            score = scores[idx] if idx < len(scores) else 0.0
            if polys and idx < len(polys):
                bbox = polys[idx].tolist()
            elif boxes is not None and idx < len(boxes):
                x_min, y_min, x_max, y_max = boxes[idx]
                bbox = [[x_min, y_min], [x_max, y_min], [x_max, y_max], [x_min, y_max]]
            else:
                bbox = None
            detections.append((bbox, text, float(score)))
        return detections

    # Legacy list/tuple format
    if isinstance(per_image, (list, tuple)):
        for detection in per_image:
            if isinstance(detection, (list, tuple)) and len(detection) >= 2:
                bbox = detection[0]
                text_conf = detection[1]
                if isinstance(text_conf, (list, tuple)) and len(text_conf) >= 1:
                    text = text_conf[0]
                    conf = text_conf[1] if len(text_conf) > 1 else 0.0
                else:
                    text = str(text_conf)
                    conf = 0.0
                detections.append((bbox, text, float(conf)))
    return detections


def redact_text_regions(image, detections, padding=5):
    """
    Redact text regions detected by PaddleOCR by filling with median color.
    Uses aggressive padding to ensure complete coverage of text.
    """
    redacted = image.copy()

    # Calculate median color for fill
    if len(image.shape) == 3:
        # Color image: median per channel
        # axis=(0,1) computes median across height and width, returning array of shape (3,)
        median_val = np.median(image, axis=(0, 1)).astype(image.dtype)
    else:
        # Grayscale
        median_val = np.median(image)

    boxes = []

    if detections:
        for bbox, text, _ in detections:
            if not text.strip() or bbox is None:
                continue
            if not isinstance(bbox, (list, tuple)) or len(bbox) < 4:
                continue
            x_coords = [pt[0] for pt in bbox]
            y_coords = [pt[1] for pt in bbox]
            x_min, x_max = int(np.min(x_coords)), int(np.max(x_coords))
            y_min, y_max = int(np.min(y_coords)), int(np.max(y_coords))
            w = x_max - x_min
            h = y_max - y_min
            if w > 0 and h > 0:
                boxes.append((x_min, y_min, w, h))

    if boxes:
        boxes = _merge_overlapping_boxes(boxes)

    for x, y, w, h in boxes:
        x1 = max(0, x - padding)
        y1 = max(0, y - padding)
        x2 = min(image.shape[1], x + w + padding)
        y2 = min(image.shape[0], y + h + padding)
        redacted[y1:y2, x1:x2] = median_val

    return redacted


def _merge_overlapping_boxes(boxes, margin=5):
    """
    Merge overlapping or near-overlapping bounding boxes.
    Handles adjacent text regions from OCR.
    
    Args:
        boxes: List of (x, y, w, h) tuples
        margin: Pixels of margin to consider boxes as overlapping
        
    Returns:
        List of merged (x, y, w, h) tuples
    """
    if not boxes:
        return []
    
    # Sort boxes by position (top-left to bottom-right)
    sorted_boxes = sorted(boxes, key=lambda b: (b[1], b[0]))
    merged = []
    
    for x, y, w, h in sorted_boxes:
        x2 = x + w
        y2 = y + h
        merged_into = False
        
        # Try to merge with existing boxes
        for i, (mx, my, mw, mh) in enumerate(merged):
            mx2 = mx + mw
            my2 = my + mh
            
            # Check if boxes overlap or are close (within margin)
            if (x <= mx2 + margin and x2 >= mx - margin and
                y <= my2 + margin and y2 >= my - margin):
                # Merge boxes
                new_x = min(x, mx)
                new_y = min(y, my)
                new_x2 = max(x2, mx2)
                new_y2 = max(y2, my2)
                merged[i] = (new_x, new_y, new_x2 - new_x, new_y2 - new_y)
                merged_into = True
                break
        
        if not merged_into:
            merged.append((x, y, w, h))
    
    return merged


def main():
    parser = argparse.ArgumentParser(description="Extract and redact text from DICOM using PaddleOCR")
    parser.add_argument("--input", required=True, help="Path to input DICOM file")
    parser.add_argument("--out-pre", default="pre_redaction.png", help="Output pre-redaction PNG (CLAHE+Window/Level)")
    parser.add_argument("--out-post", default="post_redaction.png", help="Output post-redaction PNG")
    parser.add_argument("--out-text", default="extracted_text.txt", help="Output text file")
    parser.add_argument("--transform", choices=['clahe', 'standard'], default='clahe', help="Image transform method before OCR")
    args = parser.parse_args()
    
    # Extract text
    extracted_text, image_8bit, ocr_results = extract_text_from_dicom(args.input, transform_mode=args.transform)
    
    # Create output directory if it doesn't exist
    out_dir = os.path.dirname(args.out_pre)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    
    # Save pre-redaction image
    cv2.imwrite(args.out_pre, image_8bit)
    print(f"Saved pre-redaction image to: {args.out_pre}")
    
    # Redact text regions
    redacted_image = redact_text_regions(image_8bit, ocr_results, padding=10)
    
    # Save post-redaction image
    cv2.imwrite(args.out_post, redacted_image)
    print(f"Saved post-redaction image to: {args.out_post}")
    
    # Save text
    with open(args.out_text, 'w') as f:
        f.write(extracted_text)
    print(f"Saved extracted text to: {args.out_text}")


if __name__ == "__main__":
    main()

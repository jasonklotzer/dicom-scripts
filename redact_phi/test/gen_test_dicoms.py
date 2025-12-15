
import pydicom
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.uid import UID, generate_uid
import numpy as np
import cv2
import datetime
import os

def create_dicom(filename, pixel_array, photometric_interpretation="MONOCHROME2", bits_allocated=8, bits_stored=8, high_bit=7, pixel_representation=0, window_center=None, window_width=None):
    file_meta = FileMetaDataset()
    file_meta.MediaStorageSOPClassUID = '1.2.840.10008.5.1.4.1.1.7' # Secondary Capture Image Storage
    file_meta.MediaStorageSOPInstanceUID = generate_uid()
    file_meta.TransferSyntaxUID = '1.2.840.10008.1.2.1' # Explicit VR Little Endian

    ds = FileDataset(filename, {}, file_meta=file_meta, preamble=b"\0" * 128)
    
    # Add standard elements
    ds.PatientName = f"Test^{os.path.basename(filename).replace('.dcm', '')}"
    ds.PatientID = "123456"
    ds.Modality = "OT"
    ds.StudyDate = datetime.datetime.now().strftime('%Y%m%d')
    ds.SeriesDate = datetime.datetime.now().strftime('%Y%m%d')
    ds.ContentDate = datetime.datetime.now().strftime('%Y%m%d')
    ds.StudyTime = datetime.datetime.now().strftime('%H%M%S')
    ds.SeriesTime = datetime.datetime.now().strftime('%H%M%S')
    ds.ContentTime = datetime.datetime.now().strftime('%H%M%S')
    ds.SOPClassUID = file_meta.MediaStorageSOPClassUID
    ds.SOPInstanceUID = file_meta.MediaStorageSOPInstanceUID
    ds.StudyInstanceUID = generate_uid()
    ds.SeriesInstanceUID = generate_uid()

    # Image related tags
    ds.Rows = pixel_array.shape[0]
    ds.Columns = pixel_array.shape[1]
    ds.SamplesPerPixel = 3 if len(pixel_array.shape) == 3 and pixel_array.shape[2] == 3 else 1
    ds.PhotometricInterpretation = photometric_interpretation
    ds.PlanarConfiguration = 0 if ds.SamplesPerPixel > 1 else None
    ds.BitsAllocated = bits_allocated
    ds.BitsStored = bits_stored
    ds.HighBit = high_bit
    ds.PixelRepresentation = pixel_representation
    
    if window_center is not None:
        ds.WindowCenter = window_center
    if window_width is not None:
        ds.WindowWidth = window_width

    ds.PixelData = pixel_array.tobytes()

    ds.save_as(filename)
    print(f"Created {filename}")

def add_burned_in_text(image, text_color=(255, 255, 255), shadow_color=(0, 0, 0)):
    font = cv2.FONT_HERSHEY_SIMPLEX
    texts = [
        ("Patient: John Doe", (50, 400)),
        ("DOB: 1980-01-01", (50, 430)),
        ("ID: 123456789", (50, 460)),
        ("Hospital: General Hospital", (50, 490))
    ]
    for text, pos in texts:
        if shadow_color is not None:
            cv2.putText(image, text, pos, font, 1, shadow_color, 4, cv2.LINE_AA)
        cv2.putText(image, text, pos, font, 1, text_color, 2, cv2.LINE_AA)
    return image

def generate_grayscale_8bit(filename, hidden=False):
    width, height = 512, 512
    image = np.zeros((height, width), dtype=np.uint8)
    
    # Gradient background
    for y in range(height):
        image[y, :] = y % 255

    # Add shapes
    cv2.circle(image, (256, 256), 100, 200, -1)
    cv2.rectangle(image, (50, 50), (200, 200), 100, -1)

    if hidden:
        # Text value close to background (e.g. 105 on 100 background)
        # This simulates text that might be hidden by standard W/L
        # We'll put it in the rectangle area which is 100
        cv2.putText(image, "HIDDEN PHI", (60, 100), cv2.FONT_HERSHEY_SIMPLEX, 1, 105, 2)
        # And normal text elsewhere
        add_burned_in_text(image, text_color=255, shadow_color=0)
        # Set a narrow window that might hide the "HIDDEN PHI" (105 vs 100)
        # Center 200, Width 100 -> Range 150-250. 100 and 105 both map to 0 (black).
        create_dicom(filename, image, window_center=200, window_width=100)
    else:
        add_burned_in_text(image, text_color=255, shadow_color=0)
        create_dicom(filename, image)

def generate_grayscale_16bit(filename, hidden=False):
    width, height = 512, 512
    image = np.zeros((height, width), dtype=np.uint16)
    
    # Gradient 0-65535
    for y in range(height):
        val = int((y / height) * 65535)
        image[y, :] = val

    # Add shapes
    cv2.circle(image, (256, 256), 100, 40000, -1)
    cv2.rectangle(image, (50, 50), (200, 200), 20000, -1)

    if hidden:
        # Hidden text: 20500 on 20000 background
        cv2.putText(image, "HIDDEN PHI", (60, 100), cv2.FONT_HERSHEY_SIMPLEX, 1, 20500, 2)
        add_burned_in_text(image, text_color=65535, shadow_color=0)
        # Window that hides 20000/20500 difference
        # Center 40000, Width 10000 -> Range 35000-45000. Both 20000 and 20500 are < 35000 -> Black.
        create_dicom(filename, image, bits_allocated=16, bits_stored=16, high_bit=15, window_center=40000, window_width=10000)
    else:
        add_burned_in_text(image, text_color=65535, shadow_color=0)
        create_dicom(filename, image, bits_allocated=16, bits_stored=16, high_bit=15)

def generate_color_8bit(filename, hidden=False):
    width, height = 512, 512
    image = np.zeros((height, width, 3), dtype=np.uint8)
    
    # Gradient
    for y in range(height):
        for x in range(width):
            image[y, x, 0] = x % 255
            image[y, x, 1] = y % 255
            image[y, x, 2] = (x + y) % 255

    cv2.circle(image, (256, 256), 100, (0, 255, 255), -1)
    cv2.rectangle(image, (50, 50), (200, 200), (255, 0, 255), -1)

    if hidden:
        # Hidden text: slightly different color
        # Rect is (255, 0, 255). Text (250, 0, 250)
        cv2.putText(image, "HIDDEN PHI", (60, 100), cv2.FONT_HERSHEY_SIMPLEX, 1, (250, 0, 250), 2)
        add_burned_in_text(image)
        create_dicom(filename, image, photometric_interpretation="RGB")
    else:
        add_burned_in_text(image)
        create_dicom(filename, image, photometric_interpretation="RGB")

if __name__ == "__main__":
    os.makedirs("files", exist_ok=True)
    generate_grayscale_8bit("files/gray_8bit.dcm")
    generate_grayscale_8bit("files/gray_8bit_hidden.dcm", hidden=True)
    generate_grayscale_16bit("files/gray_16bit.dcm")
    generate_grayscale_16bit("files/gray_16bit_hidden.dcm", hidden=True)
    generate_color_8bit("files/color_8bit.dcm")
    generate_color_8bit("files/color_8bit_hidden.dcm", hidden=True)


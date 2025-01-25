#!/bin/bash

# TODO: This is boilerplate code -- has not been tested!!

# Usage: process_dicom.sh <input_gcs_path> <output_gcs_path>

set -e

# --- Variables ---
INPUT_GCS_PATH=$1
OUTPUT_GCS_PATH=$2
PROJECT_ID=$(gcloud config get-value project)
REGION=$(gcloud config get-value compute/region)
DATASET_ID="dicom-temp-$(date +%s%N)"  # Temporary dataset
DICOM_STORE_ID="dicom-store-import"
DEID_STORE_ID="dicom-store-deid"
DEID_CONFIG="projects/$PROJECT_ID/locations/$REGION/datasets/$DATASET_ID/deidentifyTemplates/deid-config" # Replace with your de-identification template

# --- Functions ---

create_dataset() {
  gcloud healthcare datasets create $DATASET_ID \
    --location=$REGION \
    --description="Temporary dataset for DICOM processing"
}

create_dicom_store() {
  gcloud healthcare dicom-stores create $1 \
    --dataset=$DATASET_ID \
    --location=$REGION
}

import_dicom_data() {
  gcloud healthcare dicom-stores import $DICOM_STORE_ID \
    --dataset=$DATASET_ID \
    --location=$REGION \
    --gcs-uri=$INPUT_GCS_PATH
}

deidentify_dicom_data() {
  gcloud healthcare dicom-stores deidentify $DICOM_STORE_ID \
    --dataset=$DATASET_ID \
    --location=$REGION \
    --destination-store=$DEID_STORE_ID \
    --deidentify-config=$DEID_CONFIG
}

export_dicom_data() {
  gcloud healthcare dicom-stores export $DEID_STORE_ID \
    --dataset=$DATASET_ID \
    --location=$REGION \
    --gcs-uri=$OUTPUT_GCS_PATH
}

delete_dicom_store() {
  gcloud healthcare dicom-stores delete $1 \
    --dataset=$DATASET_ID \
    --location=$REGION \
    --quiet
}

delete_dataset() {
  gcloud healthcare datasets delete $DATASET_ID \
    --location=$REGION \
    --quiet
}

# --- Main ---

echo "Starting DICOM processing..."

create_dataset
create_dicom_store $DICOM_STORE_ID
create_dicom_store $DEID_STORE_ID

echo "Importing DICOM data..."
import_dicom_data

echo "De-identifying DICOM data..."
deidentify_dicom_data

echo "Exporting de-identified DICOM data..."
export_dicom_data

echo "Cleaning up..."
delete_dicom_store $DICOM_STORE_ID
delete_dicom_store $DEID_STORE_ID
delete_dataset

echo "DICOM processing complete!"
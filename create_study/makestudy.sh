#!/bin/bash

DCMODIFY=dcmodify

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

command -v $DCMODIFY >/dev/null 2>&1 || { fail "Command '$DCMODIFY' is required, but not installed."; }
[ $# -ne 4 ] && { fail "Usage: $0 <inputFile> <outputDir> <numOfSeries> <numOfInstances>"; }

INPUTFILE=$1
DIRECTORY=$2
SERIES=$3
INSTANCES=$4

TMPFILE=$(mktemp /tmp/makestudy.XXX)
STUDYDATE=$(date +"%Y%m%d")
STUDYTIME=$(date +"%H%M%S")
STUDYPN="PATIENT^$STUDYTIME"

echo "Creating patient $STUDYPN, studydate=$STUDYDATE, studytime=$STUDYTIME"

# Check for the directory; create it if needed
if [ ! -d "$DIRECTORY" ]; then
  mkdir -p $DIRECTORY
fi

echo "Using file $TMPFILE as the template"

# Create the template file
cp $INPUTFILE $TMPFILE
$DCMODIFY -gst -gse -nb -m "PatientName=$STUDYPN" -m "StudyDate=$STUDYDATE" -m "StudyTime=$STUDYTIME" $TMPFILE

# Copy the template file to the directory and modify it
for (( s=1; s<=$SERIES; s++ ))
do
  $DCMODIFY -gse -nb -m "SeriesNumber=$s" $TMPFILE
  for (( i=1; i<=$INSTANCES; i++ ))
  do
    NEWFILE=$DIRECTORY/$s\_$i.dcm
    echo "Creating $NEWFILE"
    cp $TMPFILE $NEWFILE
    $DCMODIFY -nb -gin -m "InstanceNumber=$i" $NEWFILE
  done
done

rm $TMPFILE

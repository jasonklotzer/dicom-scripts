#!/bin/bash

DCMODIFY=dcmodify

if [ $# -ne 4 ]
then
  echo "Usage : $0 inputfile outputdir #series #instances"
  exit
fi

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

# Make a DICOMDIR
#pushd $DIRECTORY 
#dcmmkdir *
#popd

#zip -r study.zip $DIRECTORY

rm $TMPFILE

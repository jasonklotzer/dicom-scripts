#!/bin/bash

[ $# -lt 2 ] && { echo "Usage: $0 dcmtk|dcm4che arguments"; exit 1; }

IMAGE_ALIAS=$1

case $IMAGE_ALIAS in
  dcmtk)
    IMAGE="imbio/dcmtk"
    ;;
  dcm4che)
    IMAGE="dcm4che/dcm4che-tools"
    ;;
  *)
    echo "Image alias not defined: ${IMAGE_ALIAS}"
    exit 1
    ;;
esac

shift # already processed image name

docker run -v ${PWD}:/data -w /data --rm ${IMAGE} $@
exit $?

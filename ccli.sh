#!/bin/bash

fail() {
  printf >&2 "Error: $1\n"
  exit 1
}

command -v docker >/dev/null 2>&1 || { fail "Command 'docker' is required, but not installed."; }
[ $# -lt 2 ] && { fail "Usage: $0 <dcmtk|dcm4che> [arguments]"; }

IMAGE_ALIAS=$1

case $IMAGE_ALIAS in
  dcmtk)
    IMAGE="imbio/dcmtk"
  ;;
  dcm4che)
    IMAGE="dcm4che/dcm4che-tools"
  ;;
  *)
    fail "Image alias not defined: ${IMAGE_ALIAS}"
  ;;
esac

shift # already processed image name

docker run -v ${PWD}:/data -w /data --rm ${IMAGE} $@
exit $?

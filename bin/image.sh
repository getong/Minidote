#!/usr/bin/env bash

if [ -z "$1" ]; then
    TAG=latest
else
    TAG="$1"
fi

DIR=$(dirname "$0")
IMAGE=gyounes/minidote:${TAG}
DOCKERFILE=${DIR}/../Dockerfiles/Dockerfile-tcb

rm -rf _build/

# build image
docker build \
    --no-cache \
    -t "${IMAGE}" \
    -f "${DOCKERFILE}" .

# push image
docker push "${IMAGE}"

#!/bin/sh

set -ex

. config.sh
. subr.sh

VERSION=$1
IMAGE_VERSION=$2

require SUBSCRIPTION
require VERSION
require IMAGE_VERSION

./az-sig-imgver-delete.sh ${VERSION} ${IMAGE_VERSION} amd64 ufs gen1
./az-sig-imgver-delete.sh ${VERSION} ${IMAGE_VERSION} amd64 zfs gen1
./az-sig-imgver-delete.sh ${VERSION} ${IMAGE_VERSION} amd64 ufs gen2
./az-sig-imgver-delete.sh ${VERSION} ${IMAGE_VERSION} amd64 zfs gen2
./az-sig-imgver-delete.sh ${VERSION} ${IMAGE_VERSION} arm64 ufs gen2
./az-sig-imgver-delete.sh ${VERSION} ${IMAGE_VERSION} arm64 zfs gen2
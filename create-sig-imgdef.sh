#!/bin/sh

set -ex

. config.sh
. subr.sh

VERSION=$1

require SUBSCRIPTION
require VERSION

./az-sig-imgdef-create.sh ${VERSION} amd64 ufs gen1
./az-sig-imgdef-create.sh ${VERSION} amd64 zfs gen1
./az-sig-imgdef-create.sh ${VERSION} amd64 ufs gen2
./az-sig-imgdef-create.sh ${VERSION} amd64 zfs gen2
./az-sig-imgdef-create.sh ${VERSION} arm64 ufs gen2
./az-sig-imgdef-create.sh ${VERSION} arm64 zfs gen2

#!/bin/sh

set -ex

. subr.sh

VERSION=$1

require VERSION

for d in \
	FreeBSD-${VERSION}-amd64-ufs.vhd \
	FreeBSD-${VERSION}-amd64-zfs.vhd \
	FreeBSD-${VERSION}-arm64-aarch64-ufs.vhd \
	FreeBSD-${VERSION}-arm64-aarch64-zfs.vhd \
;
do
	./az-storage-blob-delete.sh ${d}
done

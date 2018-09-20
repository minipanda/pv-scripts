#!/bin/bash

set -e

image_name=trailsd:base
realp=`realpath $0`
dir=`dirname $realp`
base=`basename $realp`

user=`id -n -u`

grep ^$user /etc/passwd > $dir/passwd.snippet
echo $user > $dir/userid

usercontainer_tag=pv-build:pv-dev-`id -u`

sh -c "cd $dir; docker build --tag=pantavisor/pv-build -f Dockerfile.build-base ."
sh -c "cd $dir; docker build --tag=$usercontainer_tag -f Dockerfile.build ."


pvr_merge_src_abs=

if [ -d "$PVR_MERGE_SRC" ]; then
	pvr_merge_src_abs=`sh -c "cd $PVR_MERGE_SRC; pwd"`
fi

pvr_merge_opts=
if [ ! -z $pvr_merge_src_abs ]; then
	pvr_merge_opts=-v$pvr_merge_src_abs:$pvr_merge_src_abs
fi

docker run \
	-e MAKEFLAGS=$MAKEFLAGS \
	-v$PWD:$PWD \
	$pvr_merge_opts \
	-w$PWD \
	--user `id -u` \
	--env-file=<(env | grep -v PATH | grep -v LD_LIBR | grep -v PKG_ | grep -v PYTHON) \
	-t --rm \
	$usercontainer_tag \
	$@


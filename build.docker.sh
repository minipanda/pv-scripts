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

docker run -v$PWD:/pwd -t --user `id -u` --env-file=<(env | grep -v PATH | grep -v LD_LIBR | grep -v PKG_ | grep -v PYTHON) --rm $usercontainer_tag $@



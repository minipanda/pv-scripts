#!/bin/bash

echo PATH: $PATH

set -e

TARGET=$1

TOP_DIR=$(cd $(dirname $0) && pwd -P)

cpus=`cat /proc/cpuinfo | grep processor | wc -l`
threads=$(($cpus + 1))

if test -z "$MAKEFLAGS"; then
	MAKEFLAGS="-j$threads"
fi

export MAKEFLAGS

target=
uboot=

udev_update() {
	if test -n "${IMG_DEVICE}"; then
		udevadm trigger
		udevadm settle
	fi
}

setup_kernel_atom() {
	find "$TOP_DIR/kernel/" -iname "atom.mk" | xargs rm -f
	if [ ! -f "$TOP_DIR/kernel/$kernel/atom.mk" ]; then
		echo "Setting up $kernel kernel"
		ln -s "$TOP_DIR/scripts/atoms/kernel-mk" "$TOP_DIR/kernel/$kernel/atom.mk"
		grep "atom.mk" "$TOP_DIR/kernel/$kernel/.gitignore" || echo "atom.mk" >> "$TOP_DIR/kernel/$kernel/.gitignore"
	fi
}

setup_uboot() {
	if [ ! -z "$uboot" ]; then
		find "$TOP_DIR/bootloader/" -iname "atom.mk" | xargs rm -f
		if [ ! -f "$TOP_DIR/bootloader/$uboot/atom.mk" ]; then
			echo "Setting up $uboot bootloader"
			ln -s "$TOP_DIR/scripts/atoms/uboot-mk" "$TOP_DIR/bootloader/$uboot/atom.mk"
			grep "atom.mk" "$TOP_DIR/bootloader/$uboot/.gitignore" || echo "atom.mk" >> "$TOP_DIR/bootloader/$uboot/.gitignore"
		fi
	fi
}

setup_alchemy () {
	export ALCHEMY_HOME=${TOP_DIR}/alchemy
	export ALCHEMY_WORKSPACE_DIR=${TOP_DIR}

	export ALCHEMY_TARGET_PRODUCT=traild
	export ALCHEMY_TARGET_PRODUCT_VARIANT=$target
	export ALCHEMY_TARGET_CONFIG_DIR=${TOP_DIR}/config/${ALCHEMY_TARGET_PRODUCT_VARIANT}
	export ALCHEMY_TARGET_OUT=${TOP_DIR}/out/${ALCHEMY_TARGET_PRODUCT_VARIANT}
	export ALCHEMY_USE_COLORS=1

	export TRAIL_BASE_DIR=${ALCHEMY_TARGET_OUT}/trail/
	export TARGET_VENDOR_DIR=${TOP_DIR}/vendor/${ALCHEMY_TARGET_PRODUCT_VARIANT}
	export PVR="${TOP_DIR}/scripts/pvr/pvr"
}

build_mmc_tools() {
	${ALCHEMY_HOME}/scripts/alchemake host.e2fsprogs
	${ALCHEMY_HOME}/scripts/alchemake host.mtools
}

build_mmc_image() {
	export DEBUGFS=${ALCHEMY_TARGET_OUT}/staging-host/usr/sbin/debugfs
	POPULATEEXTFS=${ALCHEMY_TARGET_OUT}/staging-host/bin/populate-extfs.sh
	MCOPY=${ALCHEMY_TARGET_OUT}/staging-host/usr/bin/mcopy
	if test ! -e $MCOPY; then
		echo cannot find mcopy from mtools to generate vfat partition
		exit 36
	fi
	if test ! -e $POPULATEEXTFS; then
		echo cannot find populate-extfs.sh script to build trail storage
		exit 37
	fi
	PI=$target
	source config/${target}/image.config

	echo making base mmc image
	tmpimg=${IMG_DEVICE:-`mktemp`}
	if test -z "$IMG_DEVICE" -o -n "$IMG_DEVICE_CLEAN"; then
		dd if=/dev/zero of=$tmpimg bs=1M count=0 seek=$MMC_SIZE
	else
		dd if=/dev/zero of=$tmpimg bs=1M count=1
	fi
	sync $tmpimg
	if test $? -ne 0; then
		echo error creating disk image
		exit 5
	fi
	echo making boot part
	parted -s $tmpimg -- mklabel msdos \
		mkpart p fat32 64s ${BOOT_SIZE}MiB

	if test $? -ne 0; then
		echo error partitioning image file
		exit 6
	fi
	sync $tmpimg
	udev_update

	tmpfs=`mktemp`
	echo making vfat boot fs image with size ${BOOT_SIZE}MiB
	dd if=/dev/zero of=$tmpfs bs=1M count=0 seek=$BOOT_SIZE
	mkfs.vfat -n PVUBOOT $tmpfs
	echo copying boot contents to \"$tmpfs\"
	if [ -d "${TOP_DIR}/vendor/${target}/boot/" ]; then
		$MCOPY -i $tmpfs -s ${TOP_DIR}/vendor/${target}/boot/* ::/
	fi
	if [ -d "${TOP_DIR}/out/${target}/final/boot/" ]; then
		$MCOPY -i $tmpfs -s ${TOP_DIR}/out/${target}/final/boot/u-boot.bin ::/uboot.bin
	fi
	$MCOPY -i $tmpfs -s ${TOP_DIR}/config/${target}/uboot.env ::/uboot.env
	sync $tmpfs
	echo writing boot fs to disk image part 1
	dd conv=notrunc if=$tmpfs of=$tmpimg bs=1K seek=32
	sync $tmpimg
	echo boot fs written to disk image part 1
	rm -f $tmpfs

	size_i=${BOOT_SIZE}
	part_i=2
	for part_size in ${MMC_OTHER_PART_SIZES}; do
		echo making ext4 data fs image with size ${part_size}MiB
		tmpfs=`mktemp`
		dd if=/dev/zero of=$tmpfs bs=1M count=0 seek=$part_size
		mkfs.ext4 -L pvol$part_i $tmpfs
		sync $tmpfs
		seek=$(($size_i * 1024))
		echo writing other part fs to disk image part $part_i with seek=${seek}KiB
		parted -s $tmpimg -- \
			${MMC_OTHER_MKPART}
		dd conv=notrunc if=$tmpfs of=$tmpimg bs=1K seek=$seek
		sync $tmpimg
		size_i=$(($size_i + $part_size))
		part_i=$(($part_i + 1))
		rm -f $tmpfs
	done

	if test -z "$IMG_DEVICE"; then
		DATA_SIZE=$(($MMC_SIZE - $size_i))
		SEEK_K=$(($size_i*1024))
		echo making ext4 data fs image for pv storage ${DATA_SIZE}MiB
		tmpfs=`mktemp`
		dd if=/dev/zero of=$tmpfs bs=1M count=0 seek=$DATA_SIZE
		mkfs.ext4 -L pvroot $tmpfs
		sync $tmpfs
		echo copying trail storage data to \"$tmpfs\"
		$POPULATEEXTFS ${TOP_DIR}/out/${target}/trail/final/ $tmpfs
		sync $tmpfs
		echo writing trail data fs to disk image part 2 with seek in KiB=$SEEK_K
		parted -s $tmpimg -- \
			mkpart p ext4 ${size_i}MiB -1s
		dd conv=notrunc if=$tmpfs of=$tmpimg bs=1K seek=${SEEK_K}
		sync $tmpimg
		echo trail data fs written to disk image part 2
		rm -f $tmpfs
		mv $tmpimg out/$target/${PI}-pv-${MMC_SIZE}MiB.img
	else
		echo making ext4 data fs on device ${IMG_DEVICE}${part_i}
		parted -s ${IMG_DEVICE} -- \
			mkpart p ext4 ${size_i}MiB -1s
		udev_update
		mkfs.ext4 -L pvroot ${IMG_DEVICE}${part_i}
		sync
		mntp=`mktemp -d`
		mount ${IMG_DEVICE}${part_i} $mntp
		tar -C ${TOP_DIR}/out/${target}/trail/final/ -c . | tar -C $mntp -xv
		umount $mntp
		rmdir $mntp
		sync $IMG_DEVICE
	fi

	echo -e "\nmmc image avaialble at out/$target/${PI}-pv-${MMC_SIZE}MiB.img"
	echo please flash onto ${PI} sd card with dd
}

case $TARGET in
arm-qemu)
	target="vexpress-a9"
	kernel="vexpress-a9"
	uboot="vexpress-a9"
	;;
malta-qemu)
	target="malta"
	kernel="malta"
	uboot="malta"
	;;
legacy-qemu)
	export BL_IS_PVK="yes"
	target="legacy"
	kernel="malta"
	uboot="malta"
	;;
mips-mt300a)
	export PV_NO_UBOOT=1
	export PV_BL_IS_PVK="yes"
	target="mt300a"
	kernel="mt300a"
	;;
mipsel)
	target="mipsel"
	;;
arm-rpi2-mmc)
	target="rpi2"
	setup_alchemy
	build_mmc_image
	exit 0
	;;
arm-rpi2)
	target="rpi2"
	kernel="rpi3"
	uboot="rpi3"
	;;
arm-rpi3-mmc)
	target="rpi3"
	setup_alchemy
	build_mmc_image
	exit 0
	;;
arm-rpi3)
	export LOADADDR=0x00008000
	target="rpi3"
	kernel="rpi3"
	uboot="rpi3"
	;;
arm64-hikey)
	target="hikey"
	kernel="hikey"
	;;
*)
	echo "Must define target product as first argument [arm-qemu, malta-qemu, arm-rpi3, arm-rpi2]"
	exit 1
	;;
esac

setup_alchemy

if test -z "$PANTAHUB_HOST"; then
	PANTAHUB_HOST=api.pantahub.com
fi
if test -z "$PANTAHUB_PORT"; then
	PANTAHUB_PORT=443
fi


if [ ! -z "$2" ]; then
	if [ "$2" == "upload" ]; then
		cd $TRAIL_BASE_DIR/staging
		$PVR putobjects -f https://$PANTAHUB_HOST:$PANTAHUB_PORT/objects
		cd $TOP_DIR
	else
		${ALCHEMY_HOME}/scripts/alchemake "${@:2}"
	fi
elif [ "$target" == "malta" -o "$target" == "vexpress-a9" -o "$target" == "legacy" -o "$target" == "mt300a" ]; then
	echo "Building $target target"
	setup_kernel_atom
	setup_uboot
	if [ ! -f ${TOP_DIR}/out/$target/build-host/qemu/qemu.done ]; then
		${ALCHEMY_HOME}/scripts/alchemake host.qemu
	fi
	${ALCHEMY_HOME}/scripts/alchemake all
	${ALCHEMY_HOME}/scripts/alchemake final
	${ALCHEMY_HOME}/scripts/alchemake image
	${ALCHEMY_HOME}/scripts/alchemake trail
	${ALCHEMY_HOME}/scripts/alchemake ubitrail
	${ALCHEMY_HOME}/scripts/alchemake pflash
elif [ "$target" == "mipsel" ]; then
	${ALCHEMY_HOME}/scripts/alchemake all
	${ALCHEMY_HOME}/scripts/alchemake final
	${ALCHEMY_HOME}/scripts/alchemake image
	${ALCHEMY_HOME}/scripts/alchemake trail
elif [ "$target" == "rpi2" ]; then
	setup_kernel_atom
	setup_uboot
	${ALCHEMY_HOME}/scripts/alchemake all
	${ALCHEMY_HOME}/scripts/alchemake final
	${ALCHEMY_HOME}/scripts/alchemake image
	${ALCHEMY_HOME}/scripts/alchemake trail

	build_mmc_tools
	build_mmc_image
elif [ "$target" == "rpi3" ]; then
	setup_kernel_atom
	setup_uboot
	${ALCHEMY_HOME}/scripts/alchemake all
	${ALCHEMY_HOME}/scripts/alchemake final
	${ALCHEMY_HOME}/scripts/alchemake image
	${ALCHEMY_HOME}/scripts/alchemake trail

	build_mmc_tools
	build_mmc_image
elif [ "$target" == "hikey" ]; then
	setup_kernel_atom
	${ALCHEMY_HOME}/scripts/alchemake all
	${ALCHEMY_HOME}/scripts/alchemake final
	${ALCHEMY_HOME}/scripts/alchemake image
	${ALCHEMY_HOME}/scripts/alchemake trail

	build_mmc_tools
	build_mmc_image
fi

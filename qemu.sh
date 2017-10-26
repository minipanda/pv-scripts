#!/bin/bash

path=`realpath $0`
dir=`dirname $path`
file=$1
mac=
pid=
idx=$3
demorc=$4
deviceid=`echo $file | sed -e 's/.*flash-malta-//' | sed -e 's/.img$//'`
logfile=
mac=

if [ "$EUID" -ne 0 ]
  then echo "Please run with sudo"
  exit
fi

get_ip() {
	ip=
	while true;
	do
		sleep 5
		ip=`awk '$2 == "'$mac'" {print $3}' /var/run/qemu-dnsmasq-qemu-br0.leases`
		test -z "$ip" && continue
		echo "IP for $mac is $ip"
		break
	done
	sed -i "s/ID$idx/$deviceid/g" $demorc
	sed -i "s/IP$idx/$ip/g" $demorc
	sed -i "s/FILE$idx/\/tmp\/$(basename $logfile)/g" $demorc
}

kill_qemu() {
	pkill -P $$
	kill -9 $pid
	exit 0
}

if [ -z "$file" ]; then
	echo " Usage :                  "
	echo "   $0 /path/to/pflash.img "
	exit 0
fi

random=$RANDOM
mac=$(echo $random|md5sum|sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
id=`echo $file | sed -e 's/.*flash-malta-//' | sed -e 's/.img$//'`
logfile=/tmp/qemu-$id-log

trap kill_qemu SIGTERM

runpath="/bin"
#forwardrules="-net user,hostname=qemu-malta,hostfwd=tcp::22-:22,hostfwd=udp::22-:22,hostfwd=tcp::80-:80,hostfwd=udp::80-:80"
forwardrules="-redir :22::22 -redir :80::80"
if [ ! "$(basename $PWD)" = "demo" ]; then
  forwardrules=
  runpath="./out/malta/staging-host/usr/bin"
fi

if [ "$2" == "background" ]; then
	$runpath/qemu-system-mips -M malta -m 128 -pflash $file -nographic -net tap,script=$dir/qemu-ifup -net nic,macaddr=$mac >$logfile 2>&1 </dev/null &
	pid=$!
	echo "[$pid] Running instance with $file, mac=$mac, log at $logfile"
	get_ip
else
	echo "Starting QEMU Malta instance with device-id $deviceid"
	$runpath/qemu-system-mips -M malta -m 128 -pflash $file -nographic -net tap,script=$dir/qemu-ifup -net nic,macaddr=$mac $forwardrules
fi

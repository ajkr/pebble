#!/bin/bash

set -e

set -- `getopt -un "$0" \
	-o 'm:s:d:h' \
	--long mode: \
	--long dst-bkt: \
	--long src-bkt: \
	-- "$@"`

while [ $# -gt 0 ]; do
	case "$1" in
		-h) echo "usage: $0 [flag options]"; exit;;
		-m|--mode) MODE="$2"; shift;;
		-d|--dst-bkt) DST_BKT="$2"; shift;;
		-s|--src-bkt) SRC_BKT="$2"; shift;;
		--) shift; break;;
		*) echo "invalid arg: $1"; exit 1;;
	esac
	shift
done

if [[ -z $MODE ]]; then
	echo "missing --mode"
	exit 1
elif [[ $MODE = "read" ]]; then
	READ_PCT=100
elif [[ $MODE = "write" ]]; then
	READ_PCT=0
else
	echo "--mode must be read or write"
	exit 1
fi

if [[ -n $SRC_BKT && ! $SRC_BKT =~ ^s3:// ]]; then
	echo "--src-bkt invalid: $SRC_BKT"
	exit 1
fi

if [[ -n $DST_BKT && ! $DST_BKT =~ ^s3:// ]]; then
	echo "--dst-bkt invalid: $DST_BKT"
	exit 1
fi

c=1024
for inst in c5d.large c5d.2xlarge c5d.9xlarge; do
	case $inst in
		c5d.large) CLUSTER="andrewk-w3dl1b";;
		c5d.2xlarge) CLUSTER="andrewk-tgcl39";;
		c5d.9xlarge) CLUSTER="andrewk-rn9aj2";;
	esac
	../../cockroachdb/cockroach/bin.docker_amd64/roachprod run "$CLUSTER" \
		"rm -rf /mnt/data1/db/"
	i=1
	for b in 64 256 1024; do
		case $inst in
			c5d.large) BASE_OPS=31250000;;
			c5d.2xlarge) BASE_OPS=125000000;;
			c5d.9xlarge) BASE_OPS=500000000;;
		esac
		if [ $b -eq 1024 ]; then
			OPS=$BASE_OPS
		elif [ $b -eq 256 ]; then
			OPS=$((BASE_OPS*4))
		elif [ $b -eq 64 ]; then
			OPS=$((BASE_OPS*16))
		fi

		for e in pebble rocksdb; do
			(
			if [[ -n $SRC_BKT ]]; then
				../../cockroachdb/cockroach/bin.docker_amd64/roachprod run "$CLUSTER:$i" \
					"aws s3 cp --region us-east-2 --recursive $SRC_BKT/eng=$e.b=$b.n=$OPS /mnt/data1/db/"
			fi
			./script/run_remote.sh \
				--ec2-type "$inst" \
				--cluster "$CLUSTER" \
				--base-inst $i \
				--num-trials 1 \
				--out-dir "./out/eng=$e.inst=$inst.b=$b.c=$c.n=$OPS/" \
				--num-ops "$OPS" \
				--concurrency "$c" \
				--block-bytes "$b" \
				--read-pct $READ_PCT \
				--db-dir /mnt/data1/db/ \
				--roachprod ../../cockroachdb/cockroach/bin.docker_amd64/roachprod \
				--engine "$e" \
				./pebble ;
			if [[ -n $DST_BKT ]]; then
				../../cockroachdb/cockroach/bin.docker_amd64/roachprod run "$CLUSTER:$i" \
					"aws s3 cp --region us-east-2 --recursive /mnt/data1/db/ $DST_BKT/eng=$e.b=$b.n=$OPS"
			fi
			) &
			i=$((i+1))
		done
	done
done
for job in `jobs -p`; do
	wait $job
done

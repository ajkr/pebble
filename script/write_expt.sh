#!/bin/bash

set -e

for c in 64 256 1024; do
	for b in 64 256 1024; do
		if [ $((b*c)) -lt 65536 ]; then
			# skip some very slow combinations
			continue
		fi
		for i in c5d.large c5d.2xlarge c5d.9xlarge; do
			case $i in
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
				if [[ $e = pebble ]]; then
					case $i in
						c5d.large) CLUSTER="andrewk-2i14qq";;
						c5d.2xlarge) CLUSTER="andrewk-u1nraq";;
						c5d.9xlarge) CLUSTER="andrewk-q9dpkm";;
					esac
				fi
				if [[ $e = rocksdb ]]; then
					case $i in
						c5d.large) CLUSTER="andrewk-wf4gx0";;
						c5d.2xlarge) CLUSTER="andrewk-xalv7v";;
						c5d.9xlarge) CLUSTER="andrewk-u9lmgo";;
					esac
				fi

				../../cockroachdb/cockroach/bin.docker_amd64/roachprod run "$CLUSTER" "rm -rf /mnt/data1/db/"

				./script/run_remote.sh \
					--ec2-type "$i" \
					--cluster "$CLUSTER" \
					--num-trials 3 \
					--out-dir "./out/eng=$e.inst=$i.b=$b.c=$c.n=$OPS/" \
					--num-ops "$OPS" \
					--concurrency "$c" \
					--block-bytes "$b" \
					--read-pct 0 \
					--db-dir /mnt/data1/db/ \
					--roachprod ../../cockroachdb/cockroach/bin.docker_amd64/roachprod \
					--engine "$e" \
					./pebble &
			done
		done
		for job in `jobs -p`; do
			wait $job
		done
	done
done

for c in 64 256 1024; do
	for b in 64 256 1024; do
		if [ $((b*c)) -lt 65536 ]; then
			# skip some very slow combinations
			continue
		fi
		for i in c5d.large c5d.2xlarge c5d.9xlarge; do
			case $i in
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
			./script/postprocess.sh -o ./out/ -i $i -b $b -c $c -n $OPS -t 0
		done
	done
done

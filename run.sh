#!/bin/bash

set -ex

if [ $# -lt 8 ]; then
	echo "usage: $0 <r%> <blk sz> <batch sz> <num threads> <num ops> <db dir> <out dir> <suffixes...>"
	exit 1
fi

READ_PCT="$1"
BLK_SZ="$2"
BATCH_SZ="$3"
THREADS="$4"
OPS="$5"
DB_DIR="$6"
OUT_DIR="$7"
shift 7

TEMP_DB_DIR=""
if [ -z "$DB_DIR" ]; then
	TEMP_DB_DIR="$(mktemp -d)"
	DB_DIR="$TEMP_DB_DIR"
fi

function finish {
	if [ -n "$TEMP_DB_DIR" ]; then
		rm -rf "$TEMP_DB_DIR"
	fi
}
trap finish EXIT

while [ $# -gt 0 ]; do
	SUFFIX="$1"
	/usr/bin/time "./pebble${SUFFIX}" ycsb "$DB_DIR" \
		--wait-compactions --duration 0 \
		--read-percent "$READ_PCT" \
		--min-block-bytes "$BLK_SZ" --max-block-bytes "$BLK_SZ" \
		--batch "$BATCH_SZ" \
		--concurrency "$THREADS" \
		--num-ops "$OPS" \
		|& tee "$OUT_DIR/fill${SUFFIX}.log"
	shift
done

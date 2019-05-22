#!/bin/bash

function create_db_dir() {
	local db_dir="$(mktemp -d)"
	echo "Created DB directory: $db_dir"
	$1="$db_dir"
}

function run_kv() {
	local bin_name="$(basename "$BINARY")"
	local special_args
	if [[ $bin_name =~ ^workload ]]; then
		special_args=(kv-run kv --store-dir "$DB_DIR" --max-ops "$NUM_OPS")
	elif [[ $bin_name =~ ^pebble ]]; then
		special_args=(ycsb "$DB_DIR" --num-ops "$NUM_OPS")
	else
		echo "unsupported binary: $bin_name"
		exit 1
	fi
	/usr/bin/time "${BINARY}" "${special_args[@]}" \
		--duration 0 \
		--concurrency "$CONCURRENCY" \
		--min-block-bytes "$BLOCK_BYTES" --max-block-bytes "$BLOCK_BYTES" \
		--read-percent "$READ_PCT"
}

set -- `getopt -un "$0" \
	-o 'n:b:r:d:h' \
	--long num-ops: \
	--long concurrency: \
	--long block-bytes: \
	--long batch-cnt: \
	--long read-pct: \
	--long db-dir: \
	--long binary: \
	-- "$@"`

while [ $# -gt 0 ]; do
	case "$1" in
		-h) echo "usage: $0 [flag options]"; exit;;
		--num-ops|-n) NUM_OPS="$2"; shift;;
		--concurrency) CONCURRENCY="$2"; shift;;
		--block-bytes|-b) BLOCK_BYTES="$2"; shift;;
		--batch-cnt) BATCH_CNT="$2"; shift;;
		--read-pct|-r) READ_PCT="$2"; shift;;
		--db-dir|-d) DB_DIR="$2"; shift;;
		--binary) BINARY="$2"; shift;;
		--) break;;
		-*) echo "invalid arg: $1"; exit 1;;
		*) echo "extra arg: $1"; exit 1;;
	esac
	shift
done

NUM_OPS="${NUM_OPS:-1000000}"
CONCURRENCY="${CONCURRENCY:-1}"
BLOCK_BYTES="${BLOCK_BYTES:-64}"
BATCH_CNT="${BATCH_CNT:-1}"
READ_PCT="${READ_PCT:-0}"
if [ -z "$DB_DIR" ]; then
	create_db_dir DB_DIR
fi
if [ -z "$BINARY" ]; then
	echo "must specify a binary to run"
	exit 1
fi
run_kv

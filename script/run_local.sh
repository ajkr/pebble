#!/bin/bash
set -x

function create_db_dir() {
	local db_dir="$(mktemp -d)"
	echo "Created DB directory: $db_dir"
	eval $1="$db_dir"
}

function run_kv() {
	local bin_name="$(basename "$BINARY")"
	local special_args
	if [[ $bin_name =~ ^workload ]]; then
		special_args=(kv-run kv --store-dir "$DB_DIR" --max-ops "$NUM_OPS")
	elif [[ $bin_name =~ ^pebble ]]; then
		special_args=(bench ycsb "$DB_DIR" --num-ops "$NUM_OPS")
	else
		echo "unsupported binary: $bin_name"
		exit 1
	fi
	if [[ $ENGINE = rocksdb ]]; then
		special_args+=(--rocksdb)
	elif [[ -n $ENGINE && $ENGINE != pebble ]]; then
		echo "unsupported engine: $ENGINE"
		exit 1
	fi
	local scan_pct=$READ_PCT
	local insert_pct=$((100-$READ_PCT))
	/usr/bin/time "${BINARY}" "${special_args[@]}" \
		--duration 0 \
		--initial-keys 0 \
		--prepopulated-keys "$PREPOPULATED_KEYS" \
		--concurrency "$CONCURRENCY" \
		--keys "$KEYS" \
		--values "$BLOCK_BYTES" \
		--workload "scan=$scan_pct,insert=$insert_pct" \
		--scans "$SCANS" \
		--wait-compactions
}

set -- `getopt -un "$0" \
	-o 'b:c:d:e:h:k:n:p:r:s' \
	--long binary: \
	--long block-bytes: \
	--long cache: \
	--long concurrency: \
	--long db-dir: \
	--long engine: \
	--long help: \
	--long keys: \
	--long num-ops: \
	--long prepopulated-keys: \
	--long read-pct: \
	--long scans: \
	-- "$@"`

while [ $# -gt 0 ]; do
	case "$1" in
		--binary) BINARY="$2"; shift;;
		--block-bytes|-b) BLOCK_BYTES="$2"; shift;;
		--cache|-c) CACHE="$2"; shift;;
		--concurrency) CONCURRENCY="$2"; shift;;
		--db-dir|-d) DB_DIR="$2"; shift;;
		--engine|-e) ENGINE="$2"; shift;;
		--help|-h) echo "usage: $0 [flag options]"; exit;;
		--keys|-k) KEYS="$2"; shift;;
		--num-ops|-n) NUM_OPS="$2"; shift;;
		--prepopulated-keys|-p) PREPOPULATED_KEYS="$2"; shift;;
		--read-pct|-r) READ_PCT="$2"; shift;;
		--scans|s) SCANS="$2"; shift;;
		--) break;;
		-*) echo "invalid arg: $1"; exit 1;;
		*) echo "extra arg: $1"; exit 1;;
	esac
	shift
done

BLOCK_BYTES="${BLOCK_BYTES:-64}"
CACHE="${CACHE:-$[1024*1024*1024]}"
CONCURRENCY="${CONCURRENCY:-1}"
KEYS="${KEYS:-uniform}"
NUM_OPS="${NUM_OPS:-1000000}"
PREPOPULATED_KEYS="${PREPOPULATED_KEYS:-0}"
READ_PCT="${READ_PCT:-0}"
SCANS="${SCANS:-0}"

if [ -z "$DB_DIR" ]; then
	create_db_dir DB_DIR
fi
if [ -z "$BINARY" ]; then
	echo "must specify a binary to run"
	exit 1
fi
run_kv

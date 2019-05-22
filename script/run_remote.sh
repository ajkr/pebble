#!/bin/bash

set -e

function create_cluster() {
	local num_insts=$((NUM_TRIALS*${#BINARIES[@]}))
	local cluster="andrewk-$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)"
	if [ "$num_insts" -ge 10 ]; then
		read -p "will launch $num_insts instances. are you sure?" -n 1 -r reply
		if [[ ! $reply =~ ^[Yy]$ ]]; then
			exit 1
		fi
	fi
	"$ROACHPROD_BIN" create "$cluster" \
		-n "$num_insts" \
		--aws-machine-type-ssd "$EC2_TYPE" \
		--local-ssd-no-ext4-barrier \
		--username andrewk
	echo "Created cluster: $cluster"
	eval $1="$cluster"
}

function run_workers() {
	local bin_idx
	for bin_idx in "${!BINARIES[@]}"; do
		local trial
		for trial in `seq 0 $(($NUM_TRIALS - 1))`; do
			local inst=$((1+$trial+$bin_idx*$NUM_TRIALS))
			local bin_name="$(basename "${BINARIES[$bin_idx]}")"
			local out_name="$OUT_DIR/$bin_name.$trial.log"
			local err_name="$OUT_DIR/$bin_name.$trial.err"
			local ip="$("$ROACHPROD_BIN" ip --external "$CLUSTER:$inst")"
			"$ROACHPROD_BIN" put "$CLUSTER:$inst" "${BINARIES[$bin_idx]}"
			"$ROACHPROD_BIN" put "$CLUSTER:$inst" "$SCRIPT_DIR/run_local.sh"
			"$ROACHPROD_BIN" run "$CLUSTER:$inst" -- \
				"~/run_local.sh" \
				--num-ops "$NUM_OPS" \
				--concurrency "$CONCURRENCY" \
				--block-bytes "$BLOCK_BYTES" \
				--batch-cnt "$BATCH_CNT" \
				--read-pct "$READ_PCT" \
				--db-dir "$DB_DIR" \
				--binary "~/$bin_name" \
				>"$out_name" 2>"$err_name" &
		done
	done
	for job in `jobs -p`; do
		wait $job
	done
}

set -- `getopt -un "$0" \
	-o 'c:o:n:b:r:d:h' \
	--long ec2-type: \
	--long cluster: \
	--long num-trials: \
	--long out-dir: \
	--long num-ops: \
	--long concurrency: \
	--long block-bytes: \
	--long batch-cnt: \
	--long read-pct: \
	--long db-dir: \
	--long roachprod: \
	-- "$@"`

while [ $# -gt 0 ]; do
	case "$1" in
		-h) echo "usage: $0 [flag options] binaries..."; exit;;
		--ec2-type) EC2_TYPE="$2"; shift;;
		--cluster|-c) CLUSTER="$2"; shift;;
		--num-trials) NUM_TRIALS="$2"; shift;;
		--out-dir|-o) OUT_DIR="$2"; shift;;
		--num-ops|-n) NUM_OPS="$2"; shift;;
		--concurrency) CONCURRENCY="$2"; shift;;
		--block-bytes|-b) BLOCK_BYTES="$2"; shift;;
		--batch-cnt) BATCH_CNT="$2"; shift;;
		--read-pct|-r) READ_PCT="$2"; shift;;
		--db-dir|-d) DB_DIR="$2"; shift;;
		--roachprod) ROACHPROD_BIN="$2"; shift;;
		--) shift; BINARIES=("$@"); break;;
		-*) echo "invalid arg: $1"; exit 1;;
		*) echo "extra arg: $1"; exit 1;;
	esac
	shift
done

SCRIPT_DIR="$(dirname "$0")"
EC2_TYPE="${EC2_TYPE:-c5d.xlarge}"
NUM_TRIALS="${NUM_TRIALS:-1}"
OUT_DIR="${OUT_DIR:-./out}"
mkdir -p "$OUT_DIR"
NUM_OPS="${NUM_OPS:-1000000}"
CONCURRENCY="${CONCURRENCY:-1}"
BLOCK_BYTES="${BLOCK_BYTES:-64}"
BATCH_CNT="${BATCH_CNT:-1}"
READ_PCT="${READ_PCT:-0}"
if [ -z "$DB_DIR" ]; then
	echo "missing required argument --db-dir"
	exit 1
fi
if [ -z "$BINARIES" ]; then
	echo "missing required binaries"
	exit 1
fi
if [ -z "$CLUSTER" ]; then
	create_cluster CLUSTER
fi
ROACHPROD_BIN="${ROACHPROD_BIN:-"$(which roachprod)"}"
if [ -z "$ROACHPROD_BIN" ]; then
	echo "missing required argument --roachprod"
	exit 1
fi
run_workers

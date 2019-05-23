#!/bin/bash

set -e

set -- `getopt -un "$0" \
	-o 'o:i:b:c:n:t:h' \
	--long out-dir: \
	--long inst-type: \
	--long block-bytes: \
	--long concurrency: \
	--long num-ops: \
	--long trial: \
	-- "$@"`

while [ $# -gt 1 ]; do
	case "$1" in
		-h) echo "usage: $0 [flag options]"; exit;;
		-o|--out-dir) OUT_DIR="$2"; shift;;
		-i|--inst-type) INST_TYPE="$2"; shift;;
		-b|--block-bytes) BLOCK_BYTES="$2"; shift;;
		-c|--concurrency) CONCURRENCY="$2"; shift;;
		-n|--num-ops) NUM_OPS="$2"; shift;;
		-t|--trial) TRIAL="$2"; shift;;
		--) continue;;
		-*) echo "invalid arg: $1"; exit 1;;
		*) echo "extra arg: $1"; exit 1;;
	esac
	shift
done

if [ -z "$OUT_DIR" -o -z "$INST_TYPE" -o -z "$BLOCK_BYTES" -o -z "$CONCURRENCY" -o -z "$NUM_OPS" ]; then
	echo "missing option"
	exit 1
fi
TRIAL="${TRIAL:-0}"

TITLE="$NUM_OPS insertions, $BLOCK_BYTES byte values, $CONCURRENCY writers, $INST_TYPE"
PEBBLE_FILE="$OUT_DIR/eng=pebble.inst=$INST_TYPE.b=$BLOCK_BYTES.c=$CONCURRENCY.n=$NUM_OPS/pebble.$TRIAL.log.tput"
ROCKSDB_FILE="$OUT_DIR/eng=rocksdb.inst=$INST_TYPE.b=$BLOCK_BYTES.c=$CONCURRENCY.n=$NUM_OPS/pebble.$TRIAL.log.tput"

gnuplot <<EOF
set term png
set title "$TITLE"
set xdata time
set timefmt "%Hh%Mm%Ss"
set format x "%s"
set xlabel "time (seconds)"
set ylabel "ops/sec"
set yrange [0:*]
plot "$PEBBLE_FILE" using 1:2 title 'pebble' w linespoints, "$ROCKSDB_FILE" using 1:2 title 'rocksdb' w linespoints
EOF

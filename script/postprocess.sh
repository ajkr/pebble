#!/bin/bash

set -ex

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

for e in pebble; do
	DIR="$OUT_DIR/eng=$e.inst=$INST_TYPE.b=$BLOCK_BYTES.c=$CONCURRENCY.n=$NUM_OPS"
	LOG="$DIR/pebble.$TRIAL.log"
	ERR="$DIR/pebble.$TRIAL.err"
	awk '/^ write/{print $2, $3}; /ops\(total\)/{exit}' "$LOG" | \
		sed 's/^\([0-9]\+\)s/0m\1s/' | \
		sed 's/^\([0-9]\+\)m/0h\1m/' >"$LOG.tput"

	ROW="$LOG.row"
	if [[ $e = rocksdb ]]; then
		BURST_WRITE_GB="$(awk '/^Cumulative compaction/{print $3; exit;}' "$LOG")"
		FINAL_WRITE_GB="$(awk '/^Cumulative compaction/{print $3}' "$LOG" | tail -1)"
		BURST_SIZE_GB="$(awk '/^ Sum/{print $3; exit;}' "$LOG")"
		FINAL_SIZE_GB="$(awk '/^ Sum/{print $3}' "$LOG" | tail -1)"
	else
		BURST_WAL_GB="$(awk '/WAL/ {print $12;exit}' "$LOG")"
		BURST_WAL_UNIT="$(awk '/WAL/ {print $13;exit}' "$LOG")"
		if [[ $BURST_WAL_UNIT = T ]]; then
			BURST_WAL_GB="$(echo "scale=1;1024 * $BURST_WAL_GB" | bc)"
		fi
		BURST_TOTAL_GB="$(awk '/^  total/ {print $14; exit}' "$LOG")"
		BURST_TOTAL_UNIT="$(awk '/^  total/ {print $15; exit}' "$LOG")"
		if [[ $BURST_TOTAL_UNIT = T ]]; then
			BURST_TOTAL_GB="$(echo "scale=1;1024 * $BURST_TOTAL_GB" | bc)"
		fi
		BURST_WRITE_GB="$(echo "scale=1;$BURST_TOTAL_GB-$BURST_WAL_GB" | bc)"
		FINAL_WAL_GB="$(awk '/WAL/ {print $12}' "$LOG" | tail -1)"
		FINAL_WAL_UNIT="$(awk '/WAL/ {print $13}' "$LOG" | tail -1)"
		if [[ $FINAL_WAL_UNIT = T ]]; then
			FINAL_WAL_GB="$(echo "scale=1;1024 * $FINAL_WAL_GB" | bc)"
		fi
		FINAL_TOTAL_GB="$(awk '/^  total/ {print $14}' "$LOG" | tail -1)"
		FINAL_TOTAL_UNIT="$(awk '/^  total/ {print $15}' "$LOG" | tail -1)"
		if [[ $FINAL_TOTAL_UNIT = T ]]; then
			FINAL_TOTAL_GB="$(echo "scale=1;1024 * $FINAL_TOTAL_GB" | bc)"
		fi
		FINAL_WRITE_GB="$(echo "scale=1;$FINAL_TOTAL_GB-$FINAL_WAL_GB" | bc)"
		BURST_SIZE_GB="$(awk '/^  total/{print $3; exit;}' "$LOG")"
		FINAL_SIZE_GB="$(awk '/^  total/{print $3}' "$LOG" | tail -1)"
	fi
	OPS_PER_SEC="$(awk '/ops\(total\)/{summary=1}; summary && /insert/ {print $4; exit}' "$LOG")"
	USER_SEC="$(tail -2 "$ERR" | head -1 | awk '{print $1}' | sed 's/^\([0-9.]\+\)user.*$/\1/')"
	SYS_SEC="$(tail -2 "$ERR" | head -1 | awk '{print $2}' | sed 's/^\([0-9.]\+\)system.*$/\1/')"
	TOTAL_SEC="$(echo "$USER_SEC+$SYS_SEC" | bc)"
	PEAK_RSS_KB="$(tail -2 "$ERR" | head -1 | awk '{print $6}' | sed 's/^\([0-9.]\+\)maxresident.*$/\1/')"
	PEAK_RSS_MB="$((PEAK_RSS_KB / 1024))"
	echo -e "$BURST_WRITE_GB,$FINAL_WRITE_GB,$BURST_SIZE_GB,$FINAL_SIZE_GB,$CONCURRENCY,$BLOCK_BYTES,$INST_TYPE,$NUM_OPS,$e,$OPS_PER_SEC,$TOTAL_SEC,$PEAK_RSS_MB"
done

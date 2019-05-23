#!/bin/bash

set -ex

while [ $# -ge 1 ]; do
	OUT_DIR="$1"
	shift
	for f in $OUT_DIR/*.log; do
		awk '/^ write/{print $2, $3}; /ops\(total\)/{exit}' "$f" | \
			sed 's/^\([0-9]\+\)s/0m\1s/' | \
			sed 's/^\([0-9]\+\)m/0h\1m/' >"$f.tput"
	done
done

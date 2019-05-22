#!/bin/bash

set -ex

while [ $# -ge 1 ]; do
	OUT_DIR="$1"
	shift
	for f in $OUT_DIR/*.log; do
		awk '/^[ \t]*[0-9]+/{print $1, $3}; /^Highest/{exit}' "$f" | \
			sed 's/^\([0-9]\+\)s/0m\1s/' >"$f.tput"
	done
done

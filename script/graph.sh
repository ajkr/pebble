#!/bin/bash

gnuplot <<EOF
set term png
set output "printme.png"
set title "100M insertions, 64 byte values, 64 concurrent writers"
set xdata time
set timefmt "%Mm%Ss"
set format x "%s"
set xlabel "time (seconds)"
set ylabel "ops/sec"
set yrange [0:*]
plot "$1" using 1:2 title 'baseline' w linespoints, "$2" using 1:2 title 'recycle-wal' w linespoints
EOF

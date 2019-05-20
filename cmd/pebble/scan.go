// Copyright 2018 The LevelDB-Go and Pebble Authors. All rights reserved. Use
// of this source code is governed by a BSD-style license that can be found in
// the LICENSE file.

package main

import (
	"fmt"
	"log"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/petermattis/pebble"
	"github.com/petermattis/pebble/db"
	"github.com/spf13/cobra"
	"golang.org/x/exp/rand"
)

var (
	scanRows      = 100
	scanValueSize = 8
	scanReverse   = false
)

var scanCmd = &cobra.Command{
	Use:   "scan <dir>",
	Short: "run the scan benchmark",
	Long:  ``,
	Args:  cobra.ExactArgs(1),
	Run:   runScan,
}

func runScan(cmd *cobra.Command, args []string) {
	var (
		scanned     int64
		lastScanned int64
		lastElapsed time.Duration
	)

	opts := db.Sync
	if disableWAL {
		opts = db.NoSync
	}

	runTest(args[0], test{
		init: func(d *pebble.DB, wg *sync.WaitGroup, _ *uint64) {
			const count = 100000
			const batch = 1000

			rng := rand.New(rand.NewSource(1449168817))
			randBytes := func(size int) []byte {
				data := make([]byte, size)
				for i := range data {
					data[i] = byte(rng.Int() & 0xff)
				}
				return data
			}
			keys := make([][]byte, count)

			for i := 0; i < count; {
				b := d.NewBatch()
				for end := i + batch; i < end; i++ {
					keys[i] = mvccEncode(nil, encodeUint32Ascending([]byte("key-"), uint32(i)), uint64(i+1), 0)
					value := randBytes(scanValueSize)
					if err := b.Set(keys[i], value, nil); err != nil {
						log.Fatal(err)
					}
				}
				if err := b.Commit(opts); err != nil {
					log.Fatal(err)
				}
			}

			if err := d.Flush(); err != nil {
				log.Fatal(err)
			}

			wg.Add(concurrency)
			for i := 0; i < concurrency; i++ {
				go func(i int) {
					defer wg.Done()

					rng := rand.New(rand.NewSource(uint64(i)))
					startKeyBuf := append(make([]byte, 0, 64), []byte("key-")...)
					endKeyBuf := append(make([]byte, 0, 64), []byte("key-")...)
					minTS := encodeUint64Ascending(nil, math.MaxUint64)

					for {
						startIdx := rng.Int31n(int32(len(keys) - scanRows))
						startKey := encodeUint32Ascending(startKeyBuf[:4], uint32(startIdx))
						endKey := encodeUint32Ascending(endKeyBuf[:4], uint32(startIdx+int32(scanRows)))

						var count int
						if scanReverse {
							count = mvccReverseScan(d, startKey, endKey, minTS)
						} else {
							count = mvccForwardScan(d, startKey, endKey, minTS)
						}

						if count != scanRows {
							log.Fatalf("scanned %d, expected %d\n", count, scanRows)
						}

						atomic.AddInt64(&scanned, int64(count))
					}
				}(i)
			}
		},

		tick: func(elapsed time.Duration, i int) {
			if i%20 == 0 {
				fmt.Println("_elapsed_______rows/sec_______MB/sec_______ns/row")
			}

			cur := atomic.LoadInt64(&scanned)
			dur := elapsed - lastElapsed
			fmt.Printf("%8s %14.1f %12.1f %12.1f\n",
				time.Duration(elapsed.Seconds()+0.5)*time.Second,
				float64(cur-lastScanned)/dur.Seconds(),
				float64(int64(scanValueSize)*(cur-lastScanned))/(dur.Seconds()*(1<<20)),
				float64(dur)/float64(cur-lastScanned),
			)
			lastScanned = cur
			lastElapsed = elapsed
		},

		done: func(elapsed time.Duration) {
			cur := atomic.LoadInt64(&scanned)
			fmt.Println("\n_elapsed___ops/sec(cum)__MB/sec(cum)__ns/row(avg)")
			fmt.Printf("%7.1fs %14.1f %12.1f %12.1f\n\n",
				elapsed.Seconds(),
				float64(cur)/elapsed.Seconds(),
				float64(int64(scanValueSize)*cur)/(elapsed.Seconds()*(1<<20)),
				float64(elapsed)/float64(cur),
			)
		},
	})
}

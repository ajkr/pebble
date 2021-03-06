// Copyright 2018 The LevelDB-Go and Pebble Authors. All rights reserved. Use
// of this source code is governed by a BSD-style license that can be found in
// the LICENSE file.

package sstable

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math/rand"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/petermattis/pebble/cache"
	"github.com/petermattis/pebble/db"
	"github.com/petermattis/pebble/internal/datadriven"
	"github.com/petermattis/pebble/storage"
)

func TestReader(t *testing.T) {
	makeIkey := func(s string) db.InternalKey {
		j := strings.Index(s, ":")
		seqNum, err := strconv.Atoi(s[j+1:])
		if err != nil {
			panic(err)
		}
		return db.MakeInternalKey([]byte(s[:j]), uint64(seqNum), db.InternalKeyKindSet)
	}

	fs := storage.NewMem()
	var r *Reader

	datadriven.RunTest(t, "testdata/reader", func(d *datadriven.TestData) string {
		switch d.Cmd {
		case "build":
			if r != nil {
				r.Close()
				fs.Remove("sstable")
			}

			f, err := fs.Create("sstable")
			if err != nil {
				t.Fatal(err)
			}
			w := NewWriter(f, nil, db.LevelOptions{})
			for _, e := range strings.Split(strings.TrimSpace(d.Input), ",") {
				w.Add(makeIkey(e), nil)
			}
			w.Close()

			f, err = fs.Open("sstable")
			if err != nil {
				t.Fatal(err)
			}
			r = NewReader(f, 0, nil)

		case "iter":
			for _, arg := range d.CmdArgs {
				switch arg.Key {
				case "globalSeqNum":
					if len(arg.Vals) != 1 {
						t.Fatalf("%s: arg %s expects 1 value", d.Cmd, arg.Key)
					}
					v, err := strconv.Atoi(arg.Vals[0])
					if err != nil {
						t.Fatal(err)
					}
					r.Properties.GlobalSeqNum = uint64(v)
				default:
					t.Fatalf("%s: unknown arg: %s", d.Cmd, arg.Key)
				}
			}

			iter := r.NewIter(nil)
			if err := iter.Error(); err != nil {
				t.Fatal(err)
			}

			var b bytes.Buffer
			for _, line := range strings.Split(d.Input, "\n") {
				parts := strings.Fields(line)
				if len(parts) == 0 {
					continue
				}
				switch parts[0] {
				case "seek-ge":
					if len(parts) != 2 {
						return fmt.Sprintf("seek-ge <key>\n")
					}
					iter.SeekGE([]byte(strings.TrimSpace(parts[1])))
				case "seek-lt":
					if len(parts) != 2 {
						return fmt.Sprintf("seek-lt <key>\n")
					}
					iter.SeekLT([]byte(strings.TrimSpace(parts[1])))
				case "first":
					iter.First()
				case "last":
					iter.Last()
				case "next":
					iter.Next()
				case "prev":
					iter.Prev()
				}
				if iter.Valid() {
					fmt.Fprintf(&b, "<%s:%d>", iter.Key().UserKey, iter.Key().SeqNum())
				} else if err := iter.Error(); err != nil {
					fmt.Fprintf(&b, "<err=%v>", err)
				} else {
					fmt.Fprintf(&b, ".")
				}
			}
			b.WriteString("\n")
			return b.String()

		default:
			t.Fatalf("unknown command: %s", d.Cmd)
		}
		return ""
	})
}

func buildBenchmarkTable(b *testing.B, blockSize, restartInterval int) (*Reader, [][]byte) {
	mem := storage.NewMem()
	f0, err := mem.Create("bench")
	if err != nil {
		b.Fatal(err)
	}
	defer f0.Close()

	w := NewWriter(f0, nil, db.LevelOptions{
		BlockRestartInterval: restartInterval,
		BlockSize:            blockSize,
		FilterPolicy:         nil,
	})

	var keys [][]byte
	var ikey db.InternalKey
	for i := uint64(0); i < 1e6; i++ {
		key := make([]byte, 8)
		binary.BigEndian.PutUint64(key, i)
		keys = append(keys, key)
		ikey.UserKey = key
		w.Add(ikey, nil)
	}

	if err := w.Close(); err != nil {
		b.Fatal(err)
	}

	// Re-open that filename for reading.
	f1, err := mem.Open("bench")
	if err != nil {
		b.Fatal(err)
	}
	return NewReader(f1, 0, &db.Options{
		Cache: cache.New(128 << 20),
	}), keys
}

func BenchmarkTableIterSeekGE(b *testing.B) {
	const blockSize = 32 << 10

	for _, restartInterval := range []int{16} {
		b.Run(fmt.Sprintf("restart=%d", restartInterval),
			func(b *testing.B) {
				r, keys := buildBenchmarkTable(b, blockSize, restartInterval)
				it := r.NewIter(nil)
				rng := rand.New(rand.NewSource(time.Now().UnixNano()))

				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					it.SeekGE(keys[rng.Intn(len(keys))])
				}
			})
	}
}

func BenchmarkTableIterSeekLT(b *testing.B) {
	const blockSize = 32 << 10

	for _, restartInterval := range []int{16} {
		b.Run(fmt.Sprintf("restart=%d", restartInterval),
			func(b *testing.B) {
				r, keys := buildBenchmarkTable(b, blockSize, restartInterval)
				it := r.NewIter(nil)
				rng := rand.New(rand.NewSource(time.Now().UnixNano()))

				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					it.SeekLT(keys[rng.Intn(len(keys))])
				}
			})
	}
}

func BenchmarkTableIterNext(b *testing.B) {
	const blockSize = 32 << 10

	for _, restartInterval := range []int{16} {
		b.Run(fmt.Sprintf("restart=%d", restartInterval),
			func(b *testing.B) {
				r, _ := buildBenchmarkTable(b, blockSize, restartInterval)
				it := r.NewIter(nil)

				b.ResetTimer()
				var sum int64
				for i := 0; i < b.N; i++ {
					if !it.Valid() {
						it.First()
					}
					sum += int64(binary.BigEndian.Uint64(it.Key().UserKey))
					it.Next()
				}
				if testing.Verbose() {
					fmt.Println(sum)
				}
			})
	}
}

func BenchmarkTableIterPrev(b *testing.B) {
	const blockSize = 32 << 10

	for _, restartInterval := range []int{16} {
		b.Run(fmt.Sprintf("restart=%d", restartInterval),
			func(b *testing.B) {
				r, _ := buildBenchmarkTable(b, blockSize, restartInterval)
				it := r.NewIter(nil)

				b.ResetTimer()
				var sum int64
				for i := 0; i < b.N; i++ {
					if !it.Valid() {
						it.Last()
					}
					sum += int64(binary.BigEndian.Uint64(it.Key().UserKey))
					it.Prev()
				}
				if testing.Verbose() {
					fmt.Println(sum)
				}
			})
	}
}

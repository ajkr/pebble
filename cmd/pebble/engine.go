package main

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/cockroachdb/cockroach/pkg/roachpb"
	"github.com/cockroachdb/cockroach/pkg/storage/engine"
	"github.com/cockroachdb/cockroach/pkg/util/hlc"
	"github.com/petermattis/pebble"
	"github.com/petermattis/pebble/db"
)

// These are the minimal storage engine interfaces that need to be implemented
// to support the Pebble command.
type DB interface {
	NewIter(*db.IterOptions) Iterator
	NewBatch() Batch
	Metrics() *pebble.VersionMetrics
	Flush() error
}

type Iterator interface {
	SeekGE(key []byte) bool
	Valid() bool
	Key() []byte
	Value() []byte
	First() bool
	Next() bool
	Last() bool
	Prev() bool
	Close() error
}

type Batch interface {
	Commit(opts *db.WriteOptions) error
	Set(key, value []byte, opts *db.WriteOptions) error
	LogData(data []byte, opts *db.WriteOptions) error
}

// Adapters for Pebble. Since the interfaces above are based on Pebble's
// interfaces, it can simply forward calls for everything.
type PebbleDB struct {
	d *pebble.DB
}

func (p PebbleDB) Flush() error {
	return p.d.Flush()
}

func (p PebbleDB) NewIter(opts *db.IterOptions) Iterator {
	return p.d.NewIter(opts)
}

func (p PebbleDB) NewBatch() Batch {
	return p.d.NewBatch()
}

func (p PebbleDB) Metrics() *pebble.VersionMetrics {
	return p.d.Metrics()
}

// Adapters for RocksDB

type RocksDB struct {
	d *engine.RocksDB
}

type RocksDBIterator struct {
	iter       engine.Iterator
	lowerBound []byte
	upperBound []byte
}

type RocksDBBatch struct {
	batch engine.Batch
}

func (i RocksDBIterator) SeekGE(key []byte) bool {
	// TODO: unnecessary overhead here. Change the interface.
	userKey, ts, ok := mvccSplitKey(key)
	if !ok {
		panic("mvccSplitKey failed")
	}
	if ts != nil {
		panic("non-zero ts unsupported")
	}
	i.iter.Seek(engine.MVCCKey{
		Key: userKey,
	})
	return i.Valid()
}

func (i RocksDBIterator) Valid() bool {
	valid, _ := i.iter.Valid()
	return valid
}

func (i RocksDBIterator) Key() []byte {
	key := i.iter.Key()
	// TODO: unnecessary overhead here. Change the interface.
	if key.Timestamp != (hlc.Timestamp{}) {
		panic("non-zero ts unsupported")
	}
	return mvccEncode(nil, key.Key, 0, 0)
}

func (i RocksDBIterator) Value() []byte {
	return i.iter.Value()
}

func (i RocksDBIterator) First() bool {
	return i.SeekGE(i.lowerBound)
}

func (i RocksDBIterator) Next() bool {
	i.iter.Next()
	valid, _ := i.iter.Valid()
	return valid
}

func (i RocksDBIterator) Last() bool {
	// TODO: unnecessary overhead here. Change the interface.
	userKey, ts, ok := mvccSplitKey(i.upperBound)
	if !ok {
		panic("mvccSplitKey failed")
	}
	if ts != nil {
		panic("non-zero ts unsupported")
	}
	i.iter.SeekReverse(engine.MVCCKey{
		Key: userKey,
	})
	return i.Valid()
}

func (i RocksDBIterator) Prev() bool {
	i.iter.Prev()
	valid, _ := i.iter.Valid()
	return valid
}

func (i RocksDBIterator) Close() error {
	i.iter.Close()
	return nil
}

func (b RocksDBBatch) Commit(opts *db.WriteOptions) error {
	return b.batch.Commit(opts.Sync)
}

func (b RocksDBBatch) Set(key, value []byte, _ *db.WriteOptions) error {
	// TODO: unnecessary overhead here. Change the interface.
	userKey, ts, ok := mvccSplitKey(key)
	if !ok {
		panic("mvccSplitKey failed")
	}
	if ts != nil {
		panic("non-zero ts unsupported")
	}
	return b.batch.Put(engine.MVCCKey{Key: userKey}, value)
}

func (b RocksDBBatch) LogData(data []byte, _ *db.WriteOptions) error {
	return b.batch.LogData(data)
}

func (r RocksDB) Flush() error {
	return r.d.Flush()
}

func (r RocksDB) NewIter(opts *db.IterOptions) Iterator {
	ropts := engine.IterOptions{}
	if opts != nil {
		ropts.LowerBound = opts.LowerBound
		ropts.UpperBound = opts.UpperBound
	} else {
		ropts.UpperBound = roachpb.KeyMax
	}
	iter := r.d.NewIterator(ropts)
	return RocksDBIterator{
		iter:       iter,
		lowerBound: ropts.LowerBound,
		upperBound: ropts.UpperBound,
	}
}

func (r RocksDB) NewBatch() Batch {
	return RocksDBBatch{r.d.NewBatch()}
}

func (r RocksDB) Metrics() *pebble.VersionMetrics {
	stats := r.d.GetCompactionStats()
	fmt.Printf(stats)
	var inLevelsSection bool
	var vMetrics pebble.VersionMetrics
	for _, line := range strings.Split(stats, "\n") {
		if !inLevelsSection && strings.HasPrefix(line, "-----") {
			inLevelsSection = true
			continue
		}
		if strings.HasPrefix(line, "Flush(GB):") {
			// line looks like:
			// "Flush(GB): cumulative 0.302, interval 0.302"
			// pretend cumulative flush is WAL size and L0 input since we don't have
			// access to WAL stats in rocks.
			// TODO: this is slightly different than Pebble which uses the real physical
			// WAL size. This way prevents compression ratio from affecting write-amp,
			// but it also prevents apples-to-apples w-amp comparison.
			fields := strings.Fields(line)
			field := fields[2]
			walWrittenGB, _ := strconv.ParseFloat(field[0:len(field)-1], 64)
			vMetrics.Levels[0].BytesIn = uint64(1024.0 * 1024.0 * 1024.0 * walWrittenGB)
			vMetrics.WAL.BytesWritten = vMetrics.Levels[0].BytesIn
		}
		if inLevelsSection && strings.HasPrefix(line, " Sum") {
			inLevelsSection = false
			continue
		}
		if inLevelsSection {
			fields := strings.Fields(line)
			level, _ := strconv.Atoi(fields[0][1:])
			if level < 0 || level > 6 {
				panic("expected at most 7 levels")
			}
			vMetrics.Levels[level].NumFiles, _ = strconv.ParseUint(strings.Split(fields[1], "/")[0], 10, 64)
			size, _ := strconv.ParseFloat(fields[2], 64)
			if fields[3] == "KB" {
				size *= 1024.0
			} else if fields[3] == "MB" {
				size *= 1024.0 * 1024.0
			} else if fields[3] == "GB" {
				size *= 1024.0 * 1024.0 * 1024.0
			} else {
				panic("unknown unit")
			}
			vMetrics.Levels[level].Size = uint64(size)
			vMetrics.Levels[level].Score, _ = strconv.ParseFloat(fields[4], 64)
			if level > 0 {
				bytesInGB, _ := strconv.ParseFloat(fields[6], 64)
				vMetrics.Levels[level].BytesIn = uint64(1024.0 * 1024.0 * 1024.0 * bytesInGB)
			}
			bytesMovedGB, _ := strconv.ParseFloat(fields[10], 64)
			vMetrics.Levels[level].BytesMoved = uint64(1024.0 * 1024.0 * 1024.0 * bytesMovedGB)
			bytesReadGB, _ := strconv.ParseFloat(fields[5], 64)
			vMetrics.Levels[level].BytesRead = uint64(1024.0 * 1024.0 * 1024.0 * bytesReadGB)
			bytesWrittenGB, _ := strconv.ParseFloat(fields[8], 64)
			vMetrics.Levels[level].BytesWritten = uint64(1024.0 * 1024.0 * 1024.0 * bytesWrittenGB)
		}
	}
	return &vMetrics
}

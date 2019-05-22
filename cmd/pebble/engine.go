package main

import (
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

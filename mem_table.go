// Copyright 2011 The LevelDB-Go and Pebble Authors. All rights reserved. Use
// of this source code is governed by a BSD-style license that can be found in
// the LICENSE file.

package pebble

import (
	"sync/atomic"

	"github.com/petermattis/pebble/db"
	"github.com/petermattis/pebble/internal/arenaskl"
)

func memTableEntrySize(keyBytes, valueBytes int) uint32 {
	return arenaskl.MaxNodeSize(uint32(keyBytes)+8, uint32(valueBytes))
}

// memTable is a memory-backed implementation of the db.Reader interface.
//
// It is safe to call Get, Set, and Find concurrently.
//
// A memTable's memory consumption increases monotonically, even if keys are
// deleted or values are updated with shorter slices. Users are responsible for
// explicitly compacting a memTable into a separate DB (whether in-memory or
// on-disk) when appropriate.
type memTable struct {
	cmp         db.Compare
	skl         arenaskl.Skiplist
	rangeDelSkl arenaskl.Skiplist
	emptySize   uint32
	reserved    uint32
	refs        int32
	flushedCh   chan struct{}
}

// newMemTable returns a new MemTable.
func newMemTable(o *db.Options) *memTable {
	o = o.EnsureDefaults()
	m := &memTable{
		cmp:       o.Comparer.Compare,
		refs:      1,
		flushedCh: make(chan struct{}),
	}
	arena := arenaskl.NewArena(uint32(o.MemTableSize), 0)
	m.skl.Reset(arena, m.cmp)
	m.rangeDelSkl.Reset(arena, m.cmp)
	m.emptySize = arena.Size()
	return m
}

func (m *memTable) ref() {
	atomic.AddInt32(&m.refs, 1)
}

func (m *memTable) unref() bool {
	switch v := atomic.AddInt32(&m.refs, -1); {
	case v < 0:
		panic("pebble: inconsistent reference count")
	case v == 0:
		return true
	default:
		return false
	}
}

func (m *memTable) flushed() chan struct{} {
	return m.flushedCh
}

func (m *memTable) readyForFlush() bool {
	return atomic.LoadInt32(&m.refs) == 0
}

// Get gets the value for the given key. It returns ErrNotFound if the DB does
// not contain the key.
func (m *memTable) get(key []byte) (value []byte, err error) {
	it := m.skl.NewIter()
	it.SeekGE(key)
	if !it.Valid() {
		return nil, db.ErrNotFound
	}
	ikey := it.Key()
	if m.cmp(key, ikey.UserKey) != 0 {
		return nil, db.ErrNotFound
	}
	if ikey.Kind() == db.InternalKeyKindDelete {
		return nil, db.ErrNotFound
	}
	return it.Value(), nil
}

// Prepare reserves space for the batch in the memtable and references the
// memtable preventing it from being flushed until the batch is applied. Note
// that prepare is not thread-safe, while apply is. The caller must call
// unref() after the batch has been applied.
func (m *memTable) prepare(batch *Batch) error {
	a := m.skl.Arena()
	if atomic.LoadInt32(&m.refs) == 1 {
		// If there are no other concurrent apply operations, we can update the
		// reserved bytes setting to accurately reflect how many bytes of been
		// allocated vs the over-estimation present in memTableEntrySize.
		m.reserved = a.Size()
	}

	avail := a.Capacity() - m.reserved
	if batch.memTableSize > avail {
		return arenaskl.ErrArenaFull
	}
	m.reserved += batch.memTableSize

	m.ref()
	return nil
}

func (m *memTable) apply(batch *Batch, seqNum uint64) error {
	startSeqNum := seqNum
	for iter := batch.iter(); ; seqNum++ {
		kind, ukey, value, ok := iter.next()
		if !ok {
			break
		}
		var err error
		ikey := db.MakeInternalKey(ukey, seqNum, kind)
		if kind == db.InternalKeyKindRangeDelete {
			err = m.rangeDelSkl.Add(ikey, value)
		} else {
			err = m.skl.Add(ikey, value)
		}
		if err != nil {
			return err
		}
	}
	if seqNum != startSeqNum+uint64(batch.count()) {
		panic("pebble: inconsistent batch count")
	}
	return nil
}

// newIter returns an iterator that is unpositioned (Iterator.Valid() will
// return false). The iterator can be positioned via a call to SeekGE,
// SeekLT, First or Last.
func (m *memTable) newIter(*db.IterOptions) internalIterator {
	it := m.skl.NewIter()
	return &it
}

func (m *memTable) newRangeDelIter(*db.IterOptions) internalIterator {
	it := m.rangeDelSkl.NewIter()
	return &it
}

func (m *memTable) close() error {
	return nil
}

// empty returns whether the MemTable has no key/value pairs.
func (m *memTable) empty() bool {
	return m.skl.Size() == m.emptySize
}

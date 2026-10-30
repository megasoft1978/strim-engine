package catalog

import (
	"sync"
	"time"
)

type entry struct {
	rows     []Item
	expires  time.Time
	revision uint64
}
type cache struct {
	mu           sync.Mutex
	entries      map[queryKey]entry
	hits, misses uint64
}

func newCache() *cache          { return &cache{entries: make(map[queryKey]entry)} }
func clone(items []Item) []Item { return append([]Item(nil), items...) }

func (c *cache) get(key queryKey, now time.Time, revision uint64) ([]Item, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok || now.After(e.expires) {
		c.misses++
		return nil, false
	}
	c.hits++
	return clone(e.rows), true
}

func (c *cache) put(key queryKey, rows []Item, expires time.Time, revision uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[key] = entry{clone(rows), expires, revision}
}

// CacheStats reports the number of cache lookups served and recomputed.
type CacheStats struct{ Hits, Misses uint64 }

func (c *Catalog) CacheStats() CacheStats {
	c.cache.mu.Lock()
	defer c.cache.mu.Unlock()
	return CacheStats{Hits: c.cache.hits, Misses: c.cache.misses}
}

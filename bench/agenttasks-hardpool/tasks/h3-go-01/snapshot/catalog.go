package catalog

import "time"

// Catalog serves repeat queries from an expiring cache. Mutations to Store
// must be visible on the next query even if the cache has not expired.
type Catalog struct {
	store *Store
	cache *cache
	clock Clock
	ttl   time.Duration
}

func New(store *Store, clock Clock, ttl time.Duration) *Catalog {
	if clock == nil {
		clock = systemClock{}
	}
	return &Catalog{store, newCache(), clock, ttl}
}

func (c *Catalog) Find(q Query) []Item {
	key := normalized(q)
	rows, revision := c.store.snapshot()
	now := c.clock.Now()
	if cached, ok := c.cache.get(key, now, revision); ok {
		return cached
	}
	selected := make([]Item, 0)
	for _, row := range rows {
		if matches(row, key) {
			selected = append(selected, row)
		}
	}
	selected = ordered(selected)
	if q.Limit > 0 && len(selected) > q.Limit {
		selected = selected[:q.Limit]
	}
	c.cache.put(key, selected, now.Add(c.ttl), revision)
	return clone(selected)
}

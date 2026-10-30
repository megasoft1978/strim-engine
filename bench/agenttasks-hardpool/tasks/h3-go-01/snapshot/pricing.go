package catalog

// PriceRange returns active products whose prices are between min and max,
// inclusive. Results use the same ordering as search. An inverted range
// returns no products.
func PriceRange(items []Item, min, max int64) []Item {
	out := make([]Item, 0)
	if min > max {
		return out
	}
	for _, item := range items {
		if item.Active && item.Price >= min && item.Price <= max {
			out = append(out, item)
		}
	}
	return ordered(out)
}

// Get returns a copy of the product under id, if it exists.
func (s *Store) Get(id string) (Item, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	item, ok := s.rows[id]
	return item, ok
}

// Count returns the current number of products, including inactive ones.
func (s *Store) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.rows)
}

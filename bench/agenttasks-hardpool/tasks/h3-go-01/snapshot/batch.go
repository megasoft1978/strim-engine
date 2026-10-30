package catalog

import "fmt"

// BatchResult reports each rejected row by its index in the input. Valid rows
// are stored in order, so the last valid row for a repeated ID wins.
type BatchResult struct {
	Accepted int
	Rejected map[int]string
}

// PutAll imports products without rejecting an entire shipment for one bad row.
func (s *Store) PutAll(items []Item) BatchResult {
	result := BatchResult{Rejected: make(map[int]string)}
	for i, item := range items {
		if !s.Put(item) {
			result.Rejected[i] = fmt.Sprintf("invalid product %q", item.ID)
			continue
		}
		result.Accepted++
	}
	return result
}

// DeleteAll returns the number of IDs that actually existed. Repeated IDs
// count once because a product cannot be deleted twice.
func (s *Store) DeleteAll(ids []string) int {
	deleted := 0
	for _, id := range ids {
		if s.Delete(id) {
			deleted++
		}
	}
	return deleted
}

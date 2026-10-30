package catalog

import "sync"

// Store is the authoritative set of products. All methods are safe to call
// concurrently; readers get values rather than pointers into the map.
type Store struct {
	mu       sync.RWMutex
	rows     map[string]Item
	revision uint64
}

func NewStore() *Store { return &Store{rows: make(map[string]Item)} }

func (s *Store) Put(item Item) bool {
	if !item.valid() {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rows[item.ID] = item
	s.revision++
	return true
}

func (s *Store) Delete(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.rows[id]; !ok {
		return false
	}
	delete(s.rows, id)
	s.revision++
	return true
}

func (s *Store) snapshot() ([]Item, uint64) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows := make([]Item, 0, len(s.rows))
	for _, item := range s.rows {
		rows = append(rows, item)
	}
	return rows, s.revision
}

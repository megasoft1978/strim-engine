package tenantlimit

import (
	"sync"
	"time"
)

// Store serializes accounting and policy changes for all tenants.
type Store struct {
	mu      sync.Mutex
	policy  Policy
	buckets map[string]*bucket
	windows map[string]*window
}

func NewStore(p Policy) (*Store, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	return &Store{policy: p, buckets: make(map[string]*bucket), windows: make(map[string]*window)}, nil
}

func (s *Store) bucketFor(id string, now time.Time) *bucket {
	b := s.buckets[id]
	if b == nil {
		b = newBucket(s.policy, now)
		s.buckets[id] = b
	}
	return b
}

// Allow charges cost tokens. The window guard counts successful requests.
func (s *Store) Allow(id string, now time.Time, cost int) bool {
	if id == "" || cost <= 0 {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bucketFor(id, now)
	w := s.windows[id]
	if w == nil {
		w = &window{}
		s.windows[id] = w
	}
	if !w.canTake(now, s.policy) {
		return false
	}
	if !b.take(now, cost) {
		return false
	}
	w.record(now)
	return true
}

// Available returns the current balance without charging a request.
func (s *Store) Available(id string, now time.Time) float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.bucketFor(id, now).available(now)
}

// Forget removes both accounting records for one tenant.
func (s *Store) Forget(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.buckets, id)
	delete(s.windows, id)
}

// Tenants returns the number of active bucket records.
func (s *Store) Tenants() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.buckets)
}

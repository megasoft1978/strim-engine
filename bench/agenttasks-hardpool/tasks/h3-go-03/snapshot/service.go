package tenantlimit

import "time"

// Clock allows a caller to use a controlled time source.
type Clock interface{ Now() time.Time }

type realClock struct{}

func (realClock) Now() time.Time { return time.Now() }

// Service adapts the accounting store to request-oriented callers.
type Service struct {
	store *Store
	clock Clock
}

func NewService(store *Store, clock Clock) *Service {
	if clock == nil {
		clock = realClock{}
	}
	return &Service{store: store, clock: clock}
}

func (s *Service) Permit(tenant string, cost int) Decision {
	now := s.clock.Now()
	if tenant == "" {
		return Decision{Reason: "missing tenant", At: now}
	}
	if cost <= 0 {
		return Decision{Reason: "invalid cost", At: now}
	}
	if !s.store.Allow(tenant, now, cost) {
		return Decision{Reason: "limit reached", At: now}
	}
	return Decision{Allowed: true, At: now}
}

func (s *Service) Reload(p Policy) error { return s.store.Reload(p, s.clock.Now()) }

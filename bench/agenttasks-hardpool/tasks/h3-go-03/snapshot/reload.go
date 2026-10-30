package tenantlimit

import "time"

// Reload replaces the shared policy at now. Existing balances earn the old
// rate until this instant and are then capped to the new burst. All tenants
// see the new policy atomically. Invalid policies leave the store untouched.
func (s *Store) Reload(p Policy, now time.Time) error {
	if err := p.Validate(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.policy = p
	for _, b := range s.buckets {
		b.policy = p
		b.advance(now)
		if b.tokens > float64(p.Burst) {
			b.tokens = float64(p.Burst)
		}
	}
	// Existing fallback history continues under the new window settings.
	return nil
}

// CurrentPolicy returns a copy of the active policy.
func (s *Store) CurrentPolicy() Policy {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.policy
}

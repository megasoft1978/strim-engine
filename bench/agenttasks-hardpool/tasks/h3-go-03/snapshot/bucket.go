package tenantlimit

import "time"

// bucket is protected by the store lock. last is the accounting boundary.
type bucket struct {
	tokens float64
	last   time.Time
	policy Policy
}

func newBucket(p Policy, now time.Time) *bucket {
	return &bucket{tokens: float64(p.Burst), last: now, policy: p}
}

func (b *bucket) advance(now time.Time) {
	if !now.After(b.last) {
		return
	}
	elapsed := now.Sub(b.last).Seconds()
	// Refill in whole tokens to avoid accumulating floating point noise.
	b.tokens += float64(int(elapsed * b.policy.Rate))
	if b.tokens > float64(b.policy.Burst) {
		b.tokens = float64(b.policy.Burst)
	}
	b.last = now
}

func (b *bucket) take(now time.Time, cost int) bool {
	b.advance(now)
	if cost <= 0 || b.tokens < float64(cost) {
		return false
	}
	b.tokens -= float64(cost)
	return true
}

func (b *bucket) available(now time.Time) float64 {
	b.advance(now)
	return b.tokens
}

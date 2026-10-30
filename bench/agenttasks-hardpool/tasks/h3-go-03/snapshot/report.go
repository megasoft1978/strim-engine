package tenantlimit

import (
	"sort"
	"time"
)

// Balance is a point-in-time estimate of a tenant's remaining capacity.
type Balance struct {
	Tenant string
	Tokens float64
}

// Report accounts through now and returns entries in tenant order.
func (s *Store) Report(now time.Time) []Balance {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]Balance, 0, len(s.buckets))
	for id, b := range s.buckets {
		result = append(result, Balance{id, b.available(now)})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Tenant < result[j].Tenant })
	return result
}

// Summary aggregates the balances returned by Report. It does not expose
// the store's internal maps, so callers can safely retain it across reloads.
type Summary struct {
	Tenants      int
	TotalTokens  float64
	LowestTenant string
	LowestTokens float64
}

// Summarize reports totals and identifies the tenant with the least capacity.
// Ties are resolved by tenant name. An empty store returns a zero summary.
func (s *Store) Summarize(now time.Time) Summary {
	balances := s.Report(now)
	result := Summary{Tenants: len(balances)}
	for i, b := range balances {
		result.TotalTokens += b.Tokens
		if i == 0 || b.Tokens < result.LowestTokens {
			result.LowestTenant = b.Tenant
			result.LowestTokens = b.Tokens
		}
	}
	return result
}

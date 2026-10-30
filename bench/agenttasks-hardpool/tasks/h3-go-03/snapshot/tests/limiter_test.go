package tests

import (
	limiter "example.com/tenantlimit"
	"math"
	"sync"
	"testing"
	"time"
)

var start = time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)

func policy() limiter.Policy { return limiter.Policy{Burst: 4, Rate: 2} }
func store(t *testing.T, p limiter.Policy) *limiter.Store {
	t.Helper()
	s, err := limiter.NewStore(p)
	if err != nil {
		t.Fatal(err)
	}
	return s
}
func near(t *testing.T, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-8 {
		t.Fatalf("balance = %v, want %v", got, want)
	}
}

func TestFrequentChecks(t *testing.T) {
	s := store(t, policy())
	if !s.Allow("a", start, 4) {
		t.Fatal("initial request")
	}
	for i := 1; i <= 4; i++ {
		s.Available("a", start.Add(time.Duration(i)*125*time.Millisecond))
	}
	if !s.Allow("a", start.Add(500*time.Millisecond), 1) {
		t.Fatal("request after half a second was denied")
	}
}
func TestReloadTransition(t *testing.T) {
	s := store(t, policy())
	s.Allow("a", start, 4)
	p := policy()
	p.Rate = 8
	if err := s.Reload(p, start.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	near(t, s.Available("a", start.Add(time.Second)), 2)
	near(t, s.Available("a", start.Add(125*time.Millisecond+time.Second)), 3)
}
func TestReloadBurst(t *testing.T) {
	s := store(t, policy())
	s.Allow("a", start, 2)
	p := policy()
	p.Burst = 1
	if err := s.Reload(p, start); err != nil {
		t.Fatal(err)
	}
	near(t, s.Available("a", start), 1)
	if s.Allow("a", start, 2) {
		t.Fatal("exceeded new burst")
	}
}
func TestIndependentTenantsAndForget(t *testing.T) {
	s := store(t, policy())
	s.Allow("a", start, 4)
	if !s.Allow("b", start, 4) || s.Allow("a", start, 1) {
		t.Fatal("tenants interfere")
	}
	if s.Tenants() != 2 {
		t.Fatal("tenant count")
	}
	s.Forget("a")
	if !s.Allow("a", start, 4) {
		t.Fatal("forgotten tenant did not restart")
	}
}
func TestWindowAndBoundary(t *testing.T) {
	p := policy()
	p.Burst = 20
	p.Window = time.Second
	p.WindowLimit = 2
	s := store(t, p)
	if !s.Allow("a", start, 1) || !s.Allow("a", start, 1) || s.Allow("a", start, 1) {
		t.Fatal("window limit")
	}
	if !s.Allow("a", start.Add(time.Second), 1) {
		t.Fatal("expired events should not count")
	}
}
func TestWindowHistorySurvivesReload(t *testing.T) {
	p := policy()
	p.Burst = 20
	p.Window = time.Second
	p.WindowLimit = 2
	s := store(t, p)
	s.Allow("a", start, 1)
	s.Allow("a", start, 1)
	p.WindowLimit = 3
	s.Reload(p, start)
	if !s.Allow("a", start, 1) || s.Allow("a", start, 1) {
		t.Fatal("history lost")
	}
}
func TestInvalidReloadAndReport(t *testing.T) {
	s := store(t, policy())
	s.Allow("z", start, 1)
	s.Allow("a", start, 2)
	bad := policy()
	bad.Rate = 0
	if s.Reload(bad, start) == nil || s.CurrentPolicy() != policy() {
		t.Fatal("invalid policy changed store")
	}
	r := s.Report(start)
	if len(r) != 2 || r[0].Tenant != "a" || r[1].Tenant != "z" {
		t.Fatal("report order", r)
	}
	near(t, r[0].Tokens, 2)
}
func TestConcurrentAccounting(t *testing.T) {
	p := policy()
	p.Burst = 100
	s := store(t, p)
	var wg sync.WaitGroup
	accepted := make(chan bool, 200)
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); accepted <- s.Allow("a", start, 1) }()
	}
	wg.Wait()
	close(accepted)
	n := 0
	for ok := range accepted {
		if ok {
			n++
		}
	}
	if n != 100 {
		t.Fatalf("accepted %d", n)
	}
}
func TestBadRequests(t *testing.T) {
	s := store(t, policy())
	if s.Allow("", start, 1) || s.Allow("a", start, 0) || s.Tenants() != 0 {
		t.Fatal("invalid request changed state")
	}
}

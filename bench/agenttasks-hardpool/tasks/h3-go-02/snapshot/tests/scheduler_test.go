package tests

import (
	"errors"
	d "example.com/dispatch"
	"reflect"
	"testing"
	"time"
)

var start = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

func add(t *testing.T, s *d.Scheduler, id string, deps ...string) {
	t.Helper()
	if err := s.Add(d.Job{ID: id, Interval: time.Hour, Dependencies: deps, Retry: d.RetryPolicy{Limit: 2, Delay: time.Minute, MaxDelay: 2 * time.Minute}}, start); err != nil {
		t.Fatal(err)
	}
}
func due(t *testing.T, s *d.Scheduler, at time.Time, want ...string) []d.Run {
	t.Helper()
	runs := s.Due(at)
	got := []string{}
	for _, r := range runs {
		got = append(got, r.JobID)
	}
	if !reflect.DeepEqual(got, append([]string{}, want...)) {
		t.Fatalf("runs = %v, want %v", got, want)
	}
	return runs
}
func done(t *testing.T, s *d.Scheduler, at time.Time, ok bool, ids ...string) {
	t.Helper()
	for _, id := range ids {
		if err := s.Complete(id, at, ok); err != nil {
			t.Fatal(err)
		}
	}
}
func state(t *testing.T, s *d.Scheduler, id string) d.Status {
	t.Helper()
	st, err := s.Status(id)
	if err != nil {
		t.Fatal(err)
	}
	return st
}
func TestDiamondAndIndependentHolds(t *testing.T) {
	s := d.New()
	add(t, s, "a")
	add(t, s, "b", "a")
	add(t, s, "c", "a")
	add(t, s, "d", "b", "c")
	add(t, s, "x")
	due(t, s, start, "a", "x")
	done(t, s, start, true, "a", "x")
	due(t, s, start, "b", "c")
	done(t, s, start, true, "b", "c")
	due(t, s, start, "d")
	done(t, s, start, true, "d")
	if err := s.Pause("a"); err != nil {
		t.Fatal(err)
	}
	if err := s.Pause("b"); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"a", "b", "c", "d"} {
		if !state(t, s, id).Paused {
			t.Errorf("%s should be held", id)
		}
	}
	if state(t, s, "x").Paused {
		t.Fatal("unrelated job held")
	}
	late := start.Add(2 * time.Hour)
	due(t, s, late, "x")
	done(t, s, late, true, "x")
	if err := s.Resume("a"); err != nil {
		t.Fatal(err)
	}
	if state(t, s, "a").Paused || state(t, s, "c").Paused || !state(t, s, "b").Paused || !state(t, s, "d").Paused {
		t.Fatal("unexpected overlapping holds")
	}
	due(t, s, late, "a", "c")
	done(t, s, late, true, "a", "c")
	if err := s.Resume("b"); err != nil {
		t.Fatal(err)
	}
	due(t, s, late, "b", "d")
}
func TestInFlightRetryAndOverdueResume(t *testing.T) {
	s := d.New()
	add(t, s, "worker")
	due(t, s, start, "worker")
	if err := s.Pause("worker"); err != nil {
		t.Fatal(err)
	}
	done(t, s, start, false, "worker")
	st := state(t, s, "worker")
	if !st.Paused || st.Running || st.Attempt != 1 || !st.Next.Equal(start.Add(time.Minute)) {
		t.Fatalf("state: %+v", st)
	}
	due(t, s, start.Add(5*time.Minute))
	if err := s.Resume("worker"); err != nil {
		t.Fatal(err)
	}
	r := due(t, s, start.Add(5*time.Minute), "worker")
	if r[0].Attempt != 2 {
		t.Fatal(r)
	}
	done(t, s, start.Add(5*time.Minute), false, "worker")
	due(t, s, start.Add(6*time.Minute))
	r = due(t, s, start.Add(7*time.Minute), "worker")
	if r[0].Attempt != 3 {
		t.Fatal(r)
	}
	done(t, s, start.Add(7*time.Minute), true, "worker")
	due(t, s, start.Add(7*time.Minute))
	h, err := s.HistoryFor("worker")
	if err != nil || len(h) != 3 || h[2].Attempt != 3 || !h[2].Success {
		t.Fatalf("history: %v %v", h, err)
	}
}
func TestDynamicRegistrationAndReadiness(t *testing.T) {
	s := d.New()
	add(t, s, "root")
	if err := s.Pause("root"); err != nil {
		t.Fatal(err)
	}
	add(t, s, "child", "root")
	if !state(t, s, "child").Paused {
		t.Fatal("new dependent should be held")
	}
	due(t, s, start)
	if err := s.Resume("child"); err != nil {
		t.Fatal(err)
	}
	due(t, s, start)
	if err := s.Resume("root"); err != nil {
		t.Fatal(err)
	}
	due(t, s, start, "root")
	done(t, s, start, true, "root")
	due(t, s, start, "child")
}
func TestHoldAPIAndHistoryIsolation(t *testing.T) {
	s := d.New()
	add(t, s, "a")
	if !errors.Is(s.Pause("missing"), d.ErrUnknownJob) || !errors.Is(s.Resume("missing"), d.ErrUnknownJob) {
		t.Fatal("unknown job accepted")
	}
	for i := 0; i < 2; i++ {
		if err := s.Pause("a"); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 2; i++ {
		if err := s.Resume("a"); err != nil {
			t.Fatal(err)
		}
	}
	due(t, s, start, "a")
	done(t, s, start, true, "a")
	h := s.History()
	h[0].JobID = "changed"
	if s.History()[0].JobID != "a" || s.Report()[0].Successes != 1 {
		t.Fatal("history or report corrupted")
	}
}
func TestRetryExhaustionAndValidation(t *testing.T) {
	s := d.New()
	if !errors.Is(s.Add(d.Job{ID: "bad", Interval: time.Hour, Dependencies: []string{"missing"}}, start), d.ErrUnknownJob) {
		t.Fatal("missing dependency accepted")
	}
	add(t, s, "a")
	for i := 0; i < 3; i++ {
		at := start.Add(time.Duration(i) * 2 * time.Minute)
		r := due(t, s, at, "a")
		if r[0].Attempt != i+1 {
			t.Fatal(r)
		}
		done(t, s, at, false, "a")
	}
	st := state(t, s, "a")
	if st.Attempt != 0 || st.Failures != 3 || !st.Next.Equal(start.Add(64*time.Minute)) {
		t.Fatalf("state: %+v", st)
	}
}

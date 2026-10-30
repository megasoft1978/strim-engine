package dispatch

import (
	"sort"
	"sync"
	"time"
)

type state struct {
	job         Job
	next        time.Time
	running     bool
	attempt     int
	successes   int
	failures    int
	lastSuccess time.Time
}

// Scheduler serializes its state, while callers execute returned runs outside
// the lock and report their outcomes with Complete.
type Scheduler struct {
	mu      sync.Mutex
	jobs    map[string]*state
	graph   graph
	holds   map[string]bool
	history []Outcome
}

func New() *Scheduler {
	return &Scheduler{jobs: map[string]*state{}, graph: newGraph(), holds: map[string]bool{}}
}

// Add schedules the first attempt at first. Dependencies must already exist;
// this restriction also prevents cycles. Duplicate edges are rejected.
func (s *Scheduler) Add(job Job, first time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if job.ID == "" || job.Interval <= 0 || !job.Retry.valid() {
		return ErrInvalidJob
	}
	if _, exists := s.jobs[job.ID]; exists {
		return ErrDuplicateJob
	}
	seen := map[string]bool{}
	for _, dep := range job.Dependencies {
		if dep == job.ID || seen[dep] {
			return ErrInvalidJob
		}
		if _, exists := s.jobs[dep]; !exists {
			return ErrUnknownJob
		}
		seen[dep] = true
	}
	job.Dependencies = append([]string(nil), job.Dependencies...)
	s.jobs[job.ID] = &state{job: job, next: first}
	s.graph.add(job.ID, job.Dependencies)
	return nil
}

// Due starts eligible runs in ID order. A dependency must have succeeded at
// least once. A job can have only one outstanding run.
func (s *Scheduler) Due(now time.Time) []Run {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := make([]string, 0, len(s.jobs))
	for id := range s.jobs {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	runs := []Run{}
	for _, id := range ids {
		st := s.jobs[id]
		if st.running || now.Before(st.next) || !s.ready(st) {
			continue
		}
		st.running = true
		runs = append(runs, Run{JobID: id, Attempt: st.attempt + 1, Started: now})
	}
	return runs
}

func (s *Scheduler) ready(st *state) bool {
	for _, id := range st.job.Dependencies {
		if s.jobs[id].successes == 0 {
			return false
		}
	}
	return true
}

// Complete records a result and chooses either a retry deadline or the next
// regular occurrence. Regular occurrences are measured from completion, so
// missed intervals never create a burst of catch-up runs.
func (s *Scheduler) Complete(id string, now time.Time, success bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, ok := s.jobs[id]
	if !ok {
		return ErrUnknownJob
	}
	if !st.running {
		return ErrNotRunning
	}
	st.running = false
	st.attempt++
	s.history = append(s.history, Outcome{JobID: id, Attempt: st.attempt, At: now, Success: success})
	if success {
		st.successes++
		st.lastSuccess = now
		st.attempt = 0
		st.next = now.Add(st.job.Interval)
	} else {
		st.failures++
		if st.attempt <= st.job.Retry.Limit {
			st.next = now.Add(st.job.Retry.delay(st.attempt))
		} else {
			st.attempt = 0
			st.next = now.Add(st.job.Interval)
		}
	}
	return nil
}

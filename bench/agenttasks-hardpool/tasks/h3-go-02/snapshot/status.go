package dispatch

import "time"

// Status is a point-in-time copy and cannot mutate the scheduler.
type Status struct {
	ID          string
	Next        time.Time
	Running     bool
	Attempt     int
	Successes   int
	Failures    int
	LastSuccess time.Time
	Paused      bool
}

func (s *Scheduler) Status(id string) (Status, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, ok := s.jobs[id]
	if !ok {
		return Status{}, ErrUnknownJob
	}
	return Status{ID: id, Next: st.next, Running: st.running, Attempt: st.attempt,
		Successes: st.successes, Failures: st.failures, LastSuccess: st.lastSuccess}, nil
}

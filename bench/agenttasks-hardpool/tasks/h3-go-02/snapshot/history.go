package dispatch

// History returns a detached chronological record of completed attempts.
func (s *Scheduler) History() []Outcome {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Outcome(nil), s.history...)
}

// HistoryFor returns the completed attempts for one job, in completion order.
func (s *Scheduler) HistoryFor(id string) ([]Outcome, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.jobs[id]; !ok {
		return nil, ErrUnknownJob
	}
	result := []Outcome{}
	for _, item := range s.history {
		if item.JobID == id {
			result = append(result, item)
		}
	}
	return result, nil
}

package dispatch

import "sort"

// Summary counts attempts, independent of pending schedule state.
type Summary struct {
	JobID     string
	Successes int
	Failures  int
}

// Report is sorted by ID and includes jobs with no completed attempts.
func (s *Scheduler) Report() []Summary {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]Summary, 0, len(s.jobs))
	for id, st := range s.jobs {
		result = append(result, Summary{JobID: id, Successes: st.successes, Failures: st.failures})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].JobID < result[j].JobID })
	return result
}

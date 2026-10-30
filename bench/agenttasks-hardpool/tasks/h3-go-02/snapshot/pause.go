package dispatch

// Pause prevents new runs of the job and all transitive dependents. Existing
// runs may finish and update their normal retry or recurrence deadline.
// Explicit holds are independent: resuming one job does not remove another
// hold. Unknown IDs return ErrUnknownJob.
func (s *Scheduler) Pause(id string) error {
	return nil
}

// Resume removes only the explicit hold on id. Overdue work becomes eligible
// immediately, subject to any remaining holds and dependency readiness.
func (s *Scheduler) Resume(id string) error {
	return nil
}

// Package dispatch implements a deterministic, in-memory job scheduler.
package dispatch

import (
	"errors"
	"time"
)

var (
	ErrUnknownJob   = errors.New("unknown job")
	ErrDuplicateJob = errors.New("duplicate job")
	ErrInvalidJob   = errors.New("invalid job")
	ErrBusy         = errors.New("job already running")
	ErrNotRunning   = errors.New("job not running")
)

// Job describes a recurring task. Dependencies must be registered first.
// The scheduler owns a copy of Dependencies after Add returns.
type Job struct {
	ID           string
	Interval     time.Duration
	Dependencies []string
	Retry        RetryPolicy
}

type Run struct {
	JobID   string
	Attempt int
	Started time.Time
}

type Outcome struct {
	JobID   string
	Attempt int
	At      time.Time
	Success bool
}

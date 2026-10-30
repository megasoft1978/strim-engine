package catalog

import "time"

// Clock permits callers to make expiration deterministic in tests.
type Clock interface{ Now() time.Time }
type systemClock struct{}

func (systemClock) Now() time.Time { return time.Now() }

package tenantlimit

import (
	"errors"
	"time"
)

// Policy describes a tenant's token bucket and optional emergency window.
// Rate is tokens per second. WindowLimit zero disables the fallback.
type Policy struct {
	Burst       int
	Rate        float64
	Window      time.Duration
	WindowLimit int
}

func (p Policy) Validate() error {
	if p.Burst < 1 || p.Rate <= 0 {
		return errors.New("burst and rate must be positive")
	}
	if p.WindowLimit < 0 || (p.WindowLimit > 0 && p.Window <= 0) {
		return errors.New("invalid window")
	}
	return nil
}

// Defaults is a useful starting point for a modest API client.
func Defaults() Policy {
	return Policy{Burst: 10, Rate: 2, Window: time.Minute, WindowLimit: 60}
}

package dispatch

import "time"

// RetryPolicy bounds retries after the initial attempt. Delay doubles after
// each failed retry and is capped if MaxDelay is positive.
type RetryPolicy struct {
	Limit    int
	Delay    time.Duration
	MaxDelay time.Duration
}

func (p RetryPolicy) delay(attempt int) time.Duration {
	d := p.Delay
	for i := 1; i < attempt; i++ {
		if p.MaxDelay > 0 && d >= p.MaxDelay/2 {
			return p.MaxDelay
		}
		if d > time.Duration(1<<62) {
			return time.Duration(1<<63 - 1)
		}
		d *= 2
	}
	if p.MaxDelay > 0 && d > p.MaxDelay {
		return p.MaxDelay
	}
	return d
}

func (p RetryPolicy) valid() bool {
	return p.Limit >= 0 && p.Delay >= 0 && p.MaxDelay >= 0
}

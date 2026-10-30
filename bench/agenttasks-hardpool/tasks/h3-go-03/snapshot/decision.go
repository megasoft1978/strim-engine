package tenantlimit

import "time"

// Decision describes the outcome of a single request.
type Decision struct {
	Allowed bool
	Reason  string
	At      time.Time
}

// Status maps a decision onto a conventional HTTP status code.
func (d Decision) Status() int {
	if d.Allowed {
		return 200
	}
	if d.Reason == "missing tenant" || d.Reason == "invalid cost" {
		return 400
	}
	return 429
}

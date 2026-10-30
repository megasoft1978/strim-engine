package tenantlimit

import "time"

// window stores successful request timestamps in chronological order.
type window struct{ events []time.Time }

func (w *window) canTake(now time.Time, p Policy) bool {
	if p.WindowLimit == 0 {
		return true
	}
	cutoff := now.Add(-p.Window)
	first := 0
	for first < len(w.events) && !w.events[first].After(cutoff) {
		first++
	}
	if first > 0 {
		w.events = append([]time.Time(nil), w.events[first:]...)
	}
	return len(w.events) < p.WindowLimit
}

func (w *window) record(now time.Time) { w.events = append(w.events, now) }

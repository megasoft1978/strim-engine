package catalog

import (
	"sort"
	"strings"
)

// ordered returns a fresh slice ordered by folded name, then ID. This gives
// stable pages even when the store map happens to enumerate differently.
func ordered(items []Item) []Item {
	out := append([]Item(nil), items...)
	sort.Slice(out, func(i, j int) bool {
		a, b := strings.ToLower(out[i].Name), strings.ToLower(out[j].Name)
		if a == b {
			return out[i].ID < out[j].ID
		}
		return a < b
	})
	return out
}

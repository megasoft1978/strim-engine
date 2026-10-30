package catalog

import "strings"

// Query selects active items. Empty Category matches all categories, and
// an empty Search matches every name. Searches ignore surrounding whitespace
// and case. Limit <= 0 means no limit.
type Query struct {
	Category string
	Search   string
	Limit    int
}

type queryKey struct {
	category, search string
	limit            int
}

func normalized(q Query) queryKey {
	return queryKey{strings.ToLower(strings.TrimSpace(q.Category)), strings.ToLower(strings.TrimSpace(q.Search)), q.Limit}
}

func matches(item Item, key queryKey) bool {
	return item.Active && (key.category == "" || item.Category == key.category) &&
		(key.search == "" || strings.Contains(strings.ToLower(item.Name), key.search))
}

package catalog

import (
	"sort"
	"strings"
)

// CategorySummary describes active products in a case-insensitive category.
type CategorySummary struct {
	Category     string
	Count        int
	TotalCents   int64
	MinimumCents int64
	MaximumCents int64
}

// Summarize groups active products by normalized category. The result is sorted
// by category for stable display and does not retain the input slice.
func Summarize(items []Item) []CategorySummary {
	groups := make(map[string]*CategorySummary)
	for _, item := range items {
		if !item.Active {
			continue
		}
		category := strings.ToLower(strings.TrimSpace(item.Category))
		group := groups[category]
		if group == nil {
			group = &CategorySummary{Category: category, MinimumCents: item.Price, MaximumCents: item.Price}
			groups[category] = group
		}
		group.Count++
		group.TotalCents += item.Price
		if item.Price < group.MinimumCents {
			group.MinimumCents = item.Price
		}
		if item.Price > group.MaximumCents {
			group.MaximumCents = item.Price
		}
	}
	out := make([]CategorySummary, 0, len(groups))
	for _, group := range groups {
		out = append(out, *group)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Category < out[j].Category })
	return out
}

package catalog

// TotalPrice sums prices without mutating the caller's slice. It is useful
// for display only and does not participate in cache invalidation.
func TotalPrice(items []Item) int64 {
	var total int64
	for _, item := range items {
		total += item.Price
	}
	return total
}

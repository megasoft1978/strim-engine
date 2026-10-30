package catalog

// Page is an isolated window over a query result. NextOffset is -1 when the
// requested window reaches the end. Total is the number before pagination.
type Page struct {
	Items      []Item
	Total      int
	NextOffset int
}

// FindPage ignores Query.Limit and applies offset and size after sorting.
// Negative offsets start at zero; non-positive sizes return an empty window.
func (c *Catalog) FindPage(q Query, offset, size int) Page {
	q.Limit = 0
	rows := c.Find(q)
	total := len(rows)
	if offset < 0 {
		offset = 0
	}
	if offset > total {
		offset = total
	}
	end := offset
	if size > 0 {
		// Compare with the remaining length to avoid integer overflow.
		if size >= total-offset {
			end = total
		} else {
			end = offset + size
		}
	}
	next := -1
	if end < total && size > 0 {
		next = end
	}
	return Page{Items: clone(rows[offset:end]), Total: total, NextOffset: next}
}

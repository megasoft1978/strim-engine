package catalog

// Item is a sellable product. Price is in integer cents.
type Item struct {
	ID       string
	Name     string
	Category string
	Price    int64
	Active   bool
}

func (i Item) valid() bool { return i.Validate() == nil }

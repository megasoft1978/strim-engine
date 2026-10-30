package tests

import (
	catalog "example.com/catalog"
	"reflect"
	"testing"
	"time"
)

type clock struct{ at time.Time }

func (c *clock) Now() time.Time { return c.at }
func ids(items []catalog.Item) []string {
	out := []string{}
	for _, i := range items {
		out = append(out, i.ID)
	}
	return out
}
func equal(t *testing.T, got []catalog.Item, want ...string) {
	t.Helper()
	if !reflect.DeepEqual(ids(got), want) {
		t.Fatalf("got IDs %v, want %v", ids(got), want)
	}
}
func fixture() (*catalog.Store, *catalog.Catalog, *clock) {
	s := catalog.NewStore()
	s.Put(catalog.Item{ID: "1", Name: "Apple", Category: "Fruit", Price: 120, Active: true})
	s.Put(catalog.Item{ID: "2", Name: "Apricot", Category: "Fruit", Price: 250, Active: true})
	s.Put(catalog.Item{ID: "3", Name: "Asparagus", Category: "Veg", Price: 300, Active: true})
	c := &clock{time.Unix(100, 0)}
	return s, catalog.New(s, c, time.Minute), c
}
func TestMutationVisibleImmediately(t *testing.T) {
	s, c, _ := fixture()
	q := catalog.Query{Category: "fruit"}
	equal(t, c.Find(q), "1", "2")
	s.Put(catalog.Item{ID: "4", Name: "Avocado", Category: "Fruit", Active: true})
	equal(t, c.Find(q), "1", "2", "4")
	s.Delete("1")
	equal(t, c.Find(q), "2", "4")
}
func TestExpirationAtBoundary(t *testing.T) {
	_, c, clock := fixture()
	q := catalog.Query{}
	got := c.Find(q)
	got[0].Name = "corrupted"
	clock.at = clock.at.Add(time.Minute)
	equal(t, c.Find(q), "1", "2", "3")
	if stats := c.CacheStats(); stats.Misses != 2 {
		t.Fatalf("expiration should recompute at boundary: %+v", stats)
	}
	if c.Find(q)[0].Name != "Apple" {
		t.Fatal("caller mutated cached row")
	}
}
func TestOrderingQueriesAndInactive(t *testing.T) {
	s, c, _ := fixture()
	s.Put(catalog.Item{ID: "0", Name: "APPLE", Category: "Fruit", Active: true})
	s.Put(catalog.Item{ID: "5", Name: "Apple", Category: "Fruit", Active: false})
	equal(t, c.Find(catalog.Query{Category: " FRUIT ", Search: " app ", Limit: 1}), "0")
	equal(t, c.Find(catalog.Query{Category: "fruit", Search: "APP"}), "0", "1")
}

func TestReportsAndPages(t *testing.T) {
	s, c, _ := fixture()
	result := s.PutAll([]catalog.Item{{ID: "bad", Price: -1}, {ID: "4", Name: "Banana", Category: "FRUIT", Price: 80, Active: true}})
	if result.Accepted != 1 || len(result.Rejected) != 1 {
		t.Fatalf("batch: %+v", result)
	}
	groups := catalog.Summarize(c.Find(catalog.Query{}))
	if len(groups) != 2 || groups[0].Category != "fruit" || groups[0].Count != 3 || groups[0].TotalCents != 450 {
		t.Fatalf("groups: %+v", groups)
	}
	page := c.FindPage(catalog.Query{}, 1, 2)
	if page.Total != 4 || page.NextOffset != 3 {
		t.Fatalf("page: %+v", page)
	}
	equal(t, page.Items, "2", "3")
	if s.DeleteAll([]string{"4", "4", "missing"}) != 1 {
		t.Fatal("delete count")
	}
}

func TestPriceRangeAndLookup(t *testing.T) {
	s, c, _ := fixture()
	if s.Count() != 3 {
		t.Fatal("count")
	}
	if item, ok := s.Get("2"); !ok || item.Price != 250 {
		t.Fatal("lookup")
	}
	equal(t, catalog.PriceRange(c.Find(catalog.Query{}), 120, 250), "1", "2")
	if len(catalog.PriceRange(c.Find(catalog.Query{}), 250, 120)) != 0 {
		t.Fatal("inverted range")
	}
}

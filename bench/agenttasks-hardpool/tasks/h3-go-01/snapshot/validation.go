package catalog

import (
	"errors"
	"strings"
)

// Validate explains whether a product can be imported. IDs with whitespace
// at their edges are rejected to avoid visually indistinguishable keys.
func (i Item) Validate() error {
	if strings.TrimSpace(i.ID) == "" {
		return errors.New("missing ID")
	}
	if i.ID != strings.TrimSpace(i.ID) {
		return errors.New("ID has surrounding whitespace")
	}
	if i.Price < 0 {
		return errors.New("negative price")
	}
	return nil
}

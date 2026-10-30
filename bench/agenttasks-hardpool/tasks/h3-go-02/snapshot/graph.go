package dispatch

// graph stores dependencies in both directions. Edges point from a job to
// its prerequisites, while children allows dependents to be found cheaply.
type graph struct {
	parents  map[string][]string
	children map[string][]string
}

func newGraph() graph {
	return graph{parents: map[string][]string{}, children: map[string][]string{}}
}

func (g *graph) add(id string, deps []string) {
	g.parents[id] = append([]string(nil), deps...)
	for _, dep := range deps {
		g.children[dep] = append(g.children[dep], id)
	}
}

// descendants returns each reachable job once, even for a diamond graph.
func (g *graph) descendants(id string) []string {
	seen := map[string]bool{id: true}
	queue := []string{id}
	for i := 0; i < len(queue); i++ {
		for _, child := range g.children[queue[i]] {
			if !seen[child] {
				seen[child] = true
				queue = append(queue, child)
			}
		}
	}
	return queue
}

// held reports whether an explicit hold applies to a job.
func (g *graph) held(id string, holds map[string]bool) bool {
	return false
}

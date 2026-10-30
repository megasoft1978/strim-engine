package discount;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Validated, deterministically ordered rules. */
public final class RuleBook {
    private final List<Rule> rules;

    public RuleBook(List<Rule> input) {
        if (input == null) throw new IllegalArgumentException("rules required");
        List<Rule> copy = new ArrayList<>();
        Set<String> ids = new HashSet<>();
        for (Rule rule : input) {
            if (rule == null || !ids.add(rule.id())) {
                throw new IllegalArgumentException("duplicate or null rule");
            }
            copy.add(rule);
        }
        copy.sort(Comparator.comparingInt(Rule::priority).reversed()
                            .thenComparing(Rule::id));
        rules = Collections.unmodifiableList(copy);
    }

    public List<Rule> rules() { return rules; }
}

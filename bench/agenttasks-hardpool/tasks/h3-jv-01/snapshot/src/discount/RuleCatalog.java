package discount;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Read-only catalog used by administrative screens to inspect promotions. */
public final class RuleCatalog {
    private final Map<String, Rule> byId;

    public RuleCatalog(RuleBook book) {
        if (book == null) throw new IllegalArgumentException("book required");
        Map<String, Rule> index = new LinkedHashMap<>();
        for (Rule rule : book.rules()) {
            index.put(rule.id(), rule);
        }
        byId = Collections.unmodifiableMap(index);
    }

    public Rule find(String id) {
        return byId.get(id);
    }

    public List<String> ids() {
        return Collections.unmodifiableList(new ArrayList<>(byId.keySet()));
    }

    /** Filter against the original subtotal without applying any discount. */
    public List<String> matching(Cart cart) {
        if (cart == null) throw new IllegalArgumentException("cart required");
        List<String> ids = new ArrayList<>();
        for (Rule rule : byId.values()) {
            if (rule.matches(cart)) ids.add(rule.id());
        }
        return Collections.unmodifiableList(ids);
    }

    /** Rules with the same group compete, even if their priorities differ. */
    public List<String> inGroup(String group) {
        List<String> ids = new ArrayList<>();
        for (Rule rule : byId.values()) {
            if (group == null ? rule.group() == null : group.equals(rule.group())) {
                ids.add(rule.id());
            }
        }
        return Collections.unmodifiableList(ids);
    }
}

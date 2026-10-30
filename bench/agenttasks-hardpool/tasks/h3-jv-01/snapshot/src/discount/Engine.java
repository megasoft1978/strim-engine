package discount;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Evaluates a rule book; the store can be shared across engine instances. */
public final class Engine {
    private final RuleBook book;
    private final UsageStore usage;

    public Engine(RuleBook book, UsageStore usage) {
        if (book == null || usage == null) throw new IllegalArgumentException();
        this.book = book;
        this.usage = usage;
    }

    public Result quote(Cart cart) { return evaluate(cart, false); }
    public Result redeem(Cart cart) { return evaluate(cart, true); }

    private Result evaluate(Cart cart, boolean redeem) {
        if (cart == null) throw new IllegalArgumentException("cart required");
        long remaining = cart.subtotal();
        List<Applied> applied = new ArrayList<>();
        Set<String> groups = new HashSet<>();
        for (Rule rule : book.rules()) {
            if (!rule.matches(cart)) continue;
            if (rule.group() != null && groups.contains(rule.group())) continue;
            long amount = rule.discount(remaining);
            if (amount <= 0) continue;
            remaining -= amount;
            applied.add(new Applied(rule.id(), amount));
            if (rule.group() != null) groups.add(rule.group());
        }
        return new Result(cart.subtotal(), remaining, applied);
    }
}

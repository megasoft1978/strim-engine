package discount;

/** A promotion; a zero usage limit means unlimited. */
public final class Rule {
    private final String id;
    private final int priority;
    private final String group;
    private final long minimum;
    private final Discount discount;
    private final int limit;

    public Rule(String id, int priority, String group, long minimum,
                Discount discount, int limit) {
        if (id == null || id.trim().isEmpty() || minimum < 0 ||
            discount == null || limit < 0) {
            throw new IllegalArgumentException("invalid rule");
        }
        this.id = id;
        this.priority = priority;
        this.group = group == null || group.isEmpty() ? null : group;
        this.minimum = minimum;
        this.discount = discount;
        this.limit = limit;
    }

    public String id() { return id; }
    public int priority() { return priority; }
    public String group() { return group; }
    public int limit() { return limit; }
    public boolean matches(Cart cart) { return cart.subtotal() >= minimum; }
    public long discount(long remaining) { return discount.amount(remaining); }
}

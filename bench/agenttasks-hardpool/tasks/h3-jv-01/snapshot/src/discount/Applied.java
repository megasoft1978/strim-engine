package discount;

/** One positive discount that was applied to a cart. */
public final class Applied {
    private final String ruleId;
    private final long amount;

    public Applied(String ruleId, long amount) {
        this.ruleId = ruleId;
        this.amount = amount;
    }

    public String ruleId() { return ruleId; }
    public long amount() { return amount; }
}

package discount;

/** A fixed amount off, capped at the remaining subtotal. */
public final class FixedDiscount implements Discount {
    private final long cents;

    public FixedDiscount(long cents) {
        if (cents < 0) throw new IllegalArgumentException("negative discount");
        this.cents = cents;
    }

    public long amount(long remaining) {
        return Math.min(cents, remaining);
    }
}

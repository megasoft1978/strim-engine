package discount;

/** Whole-percent discount, rounded down to cents. */
public final class PercentDiscount implements Discount {
    private final int percent;

    public PercentDiscount(int percent) {
        if (percent < 0 || percent > 100) {
            throw new IllegalArgumentException("percent out of range");
        }
        this.percent = percent;
    }

    public long amount(long remaining) {
        // Divide before multiplying to avoid overflow on large carts.
        return (remaining / 100) * percent + (remaining % 100) * percent / 100;
    }
}

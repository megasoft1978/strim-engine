package discount;

/** Computes an amount off from the current remaining subtotal. */
public interface Discount {
    long amount(long remaining);
}

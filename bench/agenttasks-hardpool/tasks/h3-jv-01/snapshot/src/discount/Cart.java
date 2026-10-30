package discount;

/** Immutable cart input; totals are in cents. */
public final class Cart {
    private final String customer;
    private final long subtotal;

    public Cart(String customer, long subtotal) {
        if (customer == null || customer.trim().isEmpty()) {
            throw new IllegalArgumentException("customer required");
        }
        if (subtotal < 0) {
            throw new IllegalArgumentException("negative subtotal");
        }
        this.customer = customer;
        this.subtotal = subtotal;
    }

    public String customer() { return customer; }
    public long subtotal() { return subtotal; }
}

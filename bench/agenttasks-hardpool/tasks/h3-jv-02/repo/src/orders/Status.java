package orders;

/** The persisted lifecycle state of an order. */
public enum Status {
    CREATED, PAID, SHIPPED, REFUNDED, CANCELLED
}

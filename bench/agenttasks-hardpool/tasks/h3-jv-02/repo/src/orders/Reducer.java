package orders;

/** Applies a validated event to the in-memory projection. */
public final class Reducer {
    public void apply(Order order, OrderEvent event) {
        switch (event.type) {
            case PAY:
                order.update(Status.PAID, 0);
                break;
            case SHIP:
                order.update(Status.SHIPPED, 0);
                break;
            case CANCEL:
                order.update(Status.CANCELLED, 0);
                break;
            case REFUND:
                order.update(Status.REFUNDED, event.amount);
                break;
            default:
                throw new IllegalArgumentException("unknown event");
        }
    }
}

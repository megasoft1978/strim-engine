package orders;

/** Rules for accepting the next event in the lifecycle. */
public final class TransitionPolicy {
    public void check(Order order, OrderEvent event) {
        if (!order.id().equals(event.orderId)) throw new IllegalArgumentException("wrong order");
        switch (event.type) {
            case PAY:
                if (event.amount != order.total()) throw new IllegalStateException("payment amount");
                break;
            case SHIP:
                requireZero(event);
                break;
            case REFUND:
                if (event.amount <= 0 || event.amount > order.retained()) {
                    throw new IllegalStateException("refund amount");
                }
                break;
            case CANCEL:
                requireZero(event);
                break;
            default:
                throw new IllegalArgumentException("unknown event");
        }
    }

    private void requireZero(OrderEvent event) {
        if (event.amount != 0) throw new IllegalStateException("unexpected amount");
    }
}

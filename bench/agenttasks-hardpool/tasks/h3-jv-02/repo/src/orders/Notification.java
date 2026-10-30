package orders;

/** User-facing notification emitted for an accepted delivery. */
public final class Notification {
    public final String orderId;
    public final Status status;
    public final int version;

    public Notification(Order order) {
        orderId = order.id();
        status = order.status();
        version = order.version();
    }

    public String message() {
        return "Order " + orderId + " is " + status.name().toLowerCase();
    }
}

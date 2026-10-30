package orders;

import java.util.Objects;

/** An external delivery of an order command. */
public final class OrderEvent {
    public final String orderId;
    public final String key;
    public final EventType type;
    public final long amount;

    public OrderEvent(String orderId, String key, EventType type, long amount) {
        this.orderId = requireText(orderId, "orderId");
        this.key = requireText(key, "key");
        this.type = Objects.requireNonNull(type, "type");
        if (amount < 0) throw new IllegalArgumentException("negative amount");
        this.amount = amount;
    }

    private static String requireText(String value, String field) {
        if (value == null || value.trim().isEmpty()) {
            throw new IllegalArgumentException(field + " is required");
        }
        return value;
    }

    public boolean samePayload(OrderEvent other) {
        return orderId.equals(other.orderId) && type == other.type && amount == other.amount;
    }

    @Override public String toString() {
        return orderId + ":" + type + ":" + amount;
    }
}

package orders;

import java.util.HashMap;
import java.util.Map;

/** Remembers accepted deliveries for retry handling. */
public final class DeliveryRegistry {
    private final Map<String, OrderEvent> accepted = new HashMap<>();

    public boolean isRetry(OrderEvent event) {
        OrderEvent previous = accepted.get(event.key);
        if (previous == null) return false;
        if (!previous.samePayload(event)) throw new IllegalStateException("key reused with different payload");
        return true;
    }

    public void remember(OrderEvent event) {
        accepted.put(event.key, event);
    }
}

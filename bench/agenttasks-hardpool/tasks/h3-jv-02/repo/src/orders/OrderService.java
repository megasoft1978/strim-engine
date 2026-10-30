package orders;

import java.util.HashMap;
import java.util.Map;

/** Single-threaded order command handler. No event is stored on rejection. */
public final class OrderService {
    private final Map<String, Order> orders = new HashMap<>();
    private final TransitionPolicy policy = new TransitionPolicy();
    private final Reducer reducer = new Reducer();
    private final DeliveryRegistry deliveries = new DeliveryRegistry();
    private final EventJournal journal = new EventJournal();
    private final NotificationOutbox outbox = new NotificationOutbox();

    public Order create(String id, long total) {
        if (orders.containsKey(id)) throw new IllegalStateException("duplicate order");
        Order order = new Order(id, total);
        orders.put(id, order);
        return order;
    }

    public Order get(String id) {
        Order order = orders.get(id);
        if (order == null) throw new IllegalArgumentException("unknown order");
        return order;
    }

    /** Returns false on a successful retry and true for a new event. */
    public boolean deliver(OrderEvent event) {
        Order order = get(event.orderId);
        policy.check(order, event);
        if (deliveries.isRetry(event)) return false;
        reducer.apply(order, event);
        journal.append(event);
        deliveries.remember(event);
        outbox.add(order);
        return true;
    }

    public EventJournal journal() { return journal; }
    public NotificationOutbox outbox() { return outbox; }
}

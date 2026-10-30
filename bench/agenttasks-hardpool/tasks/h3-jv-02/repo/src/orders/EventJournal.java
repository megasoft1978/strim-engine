package orders;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Append-only journal for audit and reports. */
public final class EventJournal {
    private final List<OrderEvent> events = new ArrayList<>();

    public void append(OrderEvent event) { events.add(event); }

    public List<OrderEvent> all() {
        return Collections.unmodifiableList(new ArrayList<>(events));
    }

    public List<OrderEvent> forOrder(String id) {
        List<OrderEvent> result = new ArrayList<>();
        for (OrderEvent event : events) {
            if (event.orderId.equals(id)) result.add(event);
        }
        return Collections.unmodifiableList(result);
    }
}

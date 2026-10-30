package orders;

import java.util.List;

/** Read-only reporting over the journal, independent of notification delivery. */
public final class OrderReport {
    private final EventJournal journal;

    public OrderReport(EventJournal journal) { this.journal = journal; }

    public long refunded(String orderId) {
        long total = 0;
        for (OrderEvent event : journal.forOrder(orderId)) {
            if (event.type == EventType.REFUND) total += event.amount;
        }
        return total;
    }

    public int count(String orderId, EventType type) {
        int count = 0;
        for (OrderEvent event : journal.forOrder(orderId)) {
            if (event.type == type) count++;
        }
        return count;
    }

    public String timeline(String orderId) {
        List<OrderEvent> events = journal.forOrder(orderId);
        StringBuilder result = new StringBuilder();
        for (OrderEvent event : events) {
            if (result.length() > 0) result.append(", ");
            result.append(event.type.name().toLowerCase());
        }
        return result.toString();
    }
}

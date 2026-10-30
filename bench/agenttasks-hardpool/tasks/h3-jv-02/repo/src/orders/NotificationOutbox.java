package orders;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** A simple outbox; dispatch is deliberately separate from command handling. */
public final class NotificationOutbox {
    private final List<Notification> pending = new ArrayList<>();

    public void add(Order order) { pending.add(new Notification(order)); }

    public List<Notification> pending() {
        return Collections.unmodifiableList(new ArrayList<>(pending));
    }

    public List<Notification> drain() {
        List<Notification> result = new ArrayList<>(pending);
        pending.clear();
        return result;
    }
}

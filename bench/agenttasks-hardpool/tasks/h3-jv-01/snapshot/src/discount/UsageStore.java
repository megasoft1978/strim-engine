package discount;

/** Usage is scoped to a customer and a stable promotion ID. */
public final class UsageStore {
    public int count(String customer, String rule) {
        return 0;
    }

    public void record(String customer, String rule) {
        // Usage persistence is not implemented yet.
    }
}

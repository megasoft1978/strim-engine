package orders;

/** State projected from accepted order events. Amounts are in minor currency units. */
public final class Order {
    private final String id;
    private final long total;
    private Status status;
    private long refunded;
    private int version;

    public Order(String id, long total) {
        if (id == null || id.trim().isEmpty()) throw new IllegalArgumentException("id");
        if (total <= 0) throw new IllegalArgumentException("total");
        this.id = id;
        this.total = total;
        this.status = Status.CREATED;
    }

    public String id() { return id; }
    public long total() { return total; }
    public Status status() { return status; }
    public long refunded() { return refunded; }
    public int version() { return version; }

    void update(Status next, long refund) {
        status = next;
        refunded += refund;
        version++;
    }

    public long retained() { return total - refunded; }
}

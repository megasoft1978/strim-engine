package orders;

/** Commands are recorded as immutable events after acceptance. */
public enum EventType {
    PAY, SHIP, REFUND, CANCEL
}

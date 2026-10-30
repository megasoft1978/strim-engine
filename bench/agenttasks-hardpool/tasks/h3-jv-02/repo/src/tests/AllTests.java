package tests;

import orders.*;

/** Small offline test harness; each scenario runs even when another fails. */
public final class AllTests {
    private static int failures;
    private static int checks;

    private static void eq(Object expected, Object actual) {
        checks++;
        if (!expected.equals(actual)) throw new AssertionError("expected " + expected + ", got " + actual);
    }

    private static void reject(Runnable action) {
        checks++;
        try { action.run(); } catch (IllegalStateException expected) { return; }
        throw new AssertionError("expected rejection");
    }

    private static OrderEvent e(String id, String key, EventType type, long amount) {
        return new OrderEvent(id, key, type, amount);
    }

    private static void run(String name, Runnable test) {
        try { test.run(); System.out.println("PASS " + name); }
        catch (Throwable error) { failures++; System.out.println("FAIL " + name + ": " + error); }
    }

    private static void normalFlow() {
        OrderService s = new OrderService();
        Order o = s.create("a", 100);
        s.deliver(e("a", "p", EventType.PAY, 100));
        s.deliver(e("a", "s", EventType.SHIP, 0));
        eq(Status.SHIPPED, o.status());
        eq(2, o.version());
        eq("pay, ship", new OrderReport(s.journal()).timeline("a"));
        eq(2, s.outbox().drain().size());
        eq(0, s.outbox().pending().size());
    }

    private static void shippingBeforePayment() {
        OrderService s = new OrderService();
        Order o = s.create("a", 100);
        reject(() -> s.deliver(e("a", "ship", EventType.SHIP, 0)));
        eq(Status.CREATED, o.status());
        eq(0, s.journal().all().size());
        eq(0, s.outbox().pending().size());
    }

    private static void terminalOrders() {
        OrderService s = new OrderService();
        Order o = s.create("a", 100);
        s.deliver(e("a", "c", EventType.CANCEL, 0));
        reject(() -> s.deliver(e("a", "p", EventType.PAY, 100)));
        eq(Status.CANCELLED, o.status());
        eq(1, o.version());
    }

    private static void retryAfterRefund() {
        OrderService s = new OrderService();
        Order o = s.create("a", 100);
        s.deliver(e("a", "pay", EventType.PAY, 100));
        OrderEvent refund = e("a", "refund", EventType.REFUND, 100);
        eq(true, s.deliver(refund));
        eq(false, s.deliver(refund));
        eq(100L, o.refunded());
        eq(2, o.version());
        eq(1, new OrderReport(s.journal()).count("a", EventType.REFUND));
        eq(2, s.outbox().pending().size());
    }

    private static void keysAreOrderScoped() {
        OrderService s = new OrderService();
        s.create("a", 100); s.create("b", 200);
        s.deliver(e("a", "pay", EventType.PAY, 100));
        s.deliver(e("b", "pay", EventType.PAY, 200));
        eq(Status.PAID, s.get("b").status());
        eq(2, s.journal().all().size());
    }

    private static void conflictAndRejection() {
        OrderService s = new OrderService();
        Order o = s.create("a", 100);
        reject(() -> s.deliver(e("a", "x", EventType.PAY, 99)));
        s.deliver(e("a", "x", EventType.PAY, 100));
        reject(() -> s.deliver(e("a", "x", EventType.REFUND, 50)));
        eq(1, o.version());
        eq(1, s.journal().all().size());
        eq(1, s.outbox().pending().size());
    }

    private static void partialRefunds() {
        OrderService s = new OrderService();
        Order o = s.create("a", 100);
        s.deliver(e("a", "p", EventType.PAY, 100));
        s.deliver(e("a", "r1", EventType.REFUND, 40));
        eq(Status.PAID, o.status());
        s.deliver(e("a", "r2", EventType.REFUND, 60));
        eq(Status.REFUNDED, o.status());
        eq(100L, new OrderReport(s.journal()).refunded("a"));
        reject(() -> s.deliver(e("a", "r3", EventType.REFUND, 1)));
    }

    private static void cancellationAndAmounts() {
        OrderService s = new OrderService();
        s.create("a", 100);
        reject(() -> s.deliver(e("a", "bad", EventType.CANCEL, 1)));
        s.deliver(e("a", "ok", EventType.CANCEL, 0));
        eq("Order a is cancelled", s.outbox().pending().get(0).message());
        reject(() -> s.deliver(e("a", "again", EventType.CANCEL, 0)));
    }

    public static void main(String[] args) {
        run("normal flow", AllTests::normalFlow);
        run("shipping before payment", AllTests::shippingBeforePayment);
        run("terminal orders", AllTests::terminalOrders);
        run("retry after refund", AllTests::retryAfterRefund);
        run("keys on separate orders", AllTests::keysAreOrderScoped);
        run("conflict and rejection", AllTests::conflictAndRejection);
        run("partial refunds", AllTests::partialRefunds);
        run("cancellation and amounts", AllTests::cancellationAndAmounts);
        System.out.println(checks + " checks, " + failures + " failures");
        if (failures != 0) System.exit(1);
    }
}

package tests;

import discount.*;
import java.util.Arrays;

public final class AllTests {
    private static int failures;
    private static int tests;

    private static void check(String name, Runnable test) {
        tests++;
        try { test.run(); System.out.println("PASS " + name); }
        catch (AssertionError | Exception e) {
            failures++;
            System.out.println("FAIL " + name + ": " + e);
        }
    }

    private static void eq(Object expected, Object actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError("expected " + expected + " but was " + actual);
        }
    }

    private static Rule rule(String id, int priority, String group, long min,
                             long cents, int limit) {
        return new Rule(id, priority, group, min, new FixedDiscount(cents), limit);
    }

    private static Engine engine(UsageStore store, Rule... rules) {
        return new Engine(new RuleBook(Arrays.asList(rules)), store);
    }

    private static String ids(Result result) {
        StringBuilder s = new StringBuilder();
        for (Applied a : result.applied()) {
            if (s.length() > 0) s.append(',');
            s.append(a.ruleId());
        }
        return s.toString();
    }

    public static void main(String[] args) {
        check("stacking and exclusive priority", () -> {
            Engine e = engine(new UsageStore(), rule("low", 1, "club", 0, 200, 0),
                rule("high", 9, "club", 0, 100, 0), rule("stack", 0, null, 0, 50, 0));
            Result r = e.redeem(new Cart("a", 1000));
            eq("high,stack", ids(r)); eq(850L, r.remaining());
            eq("subtotal:1000\nhigh:-100\nstack:-50\ntotal:850", Receipt.format(r));
        });
        check("redemption across engine instances", () -> {
            UsageStore store = new UsageStore();
            Rule r = rule("welcome", 2, null, 0, 100, 2);
            Engine first = engine(store, r); Cart cart = new Cart("alice", 500);
            eq(400L, first.redeem(cart).remaining());
            eq(400L, first.redeem(cart).remaining());
            Engine second = engine(store, r);
            eq(500L, second.redeem(cart).remaining());
            eq(2, store.count("alice", "welcome"));
        });
        check("customers and rule IDs are independent", () -> {
            UsageStore store = new UsageStore();
            Engine e = engine(store, rule("a", 2, null, 0, 100, 1),
                rule("b", 1, null, 0, 50, 2));
            Cart alice = new Cart("alice", 500), bob = new Cart("bob", 500);
            eq("a,b", ids(e.redeem(alice)));
            eq("b", ids(e.redeem(alice)));
            eq("", ids(e.redeem(alice)));
            eq("a,b", ids(e.redeem(bob)));
        });
        check("quotes do not consume", () -> {
            UsageStore store = new UsageStore();
            Engine e = engine(store, rule("one", 0, null, 0, 50, 1));
            Cart c = new Cart("c", 100);
            eq(50L, e.quote(c).remaining()); eq(50L, e.quote(c).remaining());
            eq(0, store.count("c", "one"));
            eq(50L, e.redeem(c).remaining());
            eq(100L, e.quote(c).remaining());
        });
        check("exhausted group winner falls through", () -> {
            UsageStore s = new UsageStore();
            Engine e = engine(s, rule("a", 10, "g", 0, 100, 1),
                rule("b", 5, "g", 0, 40, 1));
            Cart c = new Cart("c", 1000);
            eq("a", ids(e.redeem(c))); eq(0, s.count("c", "b"));
            eq("b", ids(e.redeem(c))); eq("", ids(e.redeem(c)));
        });
        check("only positive matching discounts count", () -> {
            UsageStore s = new UsageStore();
            Engine e = engine(s, rule("threshold", 3, null, 200, 10, 1),
                rule("zero", 2, null, 0, 0, 1), rule("full", 1, null, 0, 100, 1),
                rule("after", 0, null, 0, 10, 1));
            eq("full", ids(e.redeem(new Cart("c", 100))));
            eq(0, s.count("c", "threshold")); eq(0, s.count("c", "zero"));
            eq(0, s.count("c", "after"));
            eq("threshold,after", ids(e.redeem(new Cart("c", 300))));
        });
        check("unlimited and stable order", () -> {
            UsageStore s = new UsageStore();
            Engine e = engine(s, rule("z", 1, null, 0, 1, 0),
                rule("a", 1, null, 0, 1, 0));
            for (int i = 0; i < 3; i++) eq("a,z", ids(e.redeem(new Cart("c", 10))));
        });
        check("percentage and immutable result", () -> {
            Rule r = new Rule("p", 0, null, 0, new PercentDiscount(25), 0);
            Result result = engine(new UsageStore(), r).quote(new Cart("x", 101));
            eq(76L, result.remaining()); eq(25L, result.saved());
            try { result.applied().clear(); throw new AssertionError("mutable result"); }
            catch (UnsupportedOperationException expected) { }
        });
        check("catalog and reporting", () -> {
            Rule a = rule("a", 2, "g", 100, 10, 0);
            Rule b = rule("b", 1, null, 0, 5, 0);
            RuleBook book = new RuleBook(Arrays.asList(b, a));
            RuleCatalog catalog = new RuleCatalog(book);
            eq(Arrays.asList("a", "b"), catalog.ids());
            eq(Arrays.asList("b"), catalog.matching(new Cart("x", 50)));
            eq(Arrays.asList("a"), catalog.inGroup("g"));
            Engine e = new Engine(book, new UsageStore());
            SalesReport report = new SalesReport(Arrays.asList(
                e.quote(new Cart("x", 100)), e.quote(new Cart("y", 50))));
            eq(2, report.orders()); eq(20L, report.savings());
            eq(130L, report.collected()); eq(10L, report.savingsFor("a"));
        });
        check("validation", () -> {
            try { new Cart("x", -1); throw new AssertionError("negative cart"); }
            catch (IllegalArgumentException expected) { }
            Rule a = rule("a", 0, null, 0, 1, 0);
            try { new RuleBook(Arrays.asList(a, a)); throw new AssertionError("duplicate id"); }
            catch (IllegalArgumentException expected) { }
        });
        System.out.println(tests + " tests, " + failures + " failures");
        if (failures != 0) System.exit(1);
    }
}

package discount;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Aggregates completed calculation results for a batch report. */
public final class SalesReport {
    private final int orders;
    private final long original;
    private final long savings;
    private final Map<String, Long> savingsByRule;

    public SalesReport(List<Result> results) {
        if (results == null) throw new IllegalArgumentException("results required");
        int orderCount = 0;
        long subtotal = 0;
        long saved = 0;
        Map<String, Long> perRule = new LinkedHashMap<>();
        for (Result result : results) {
            if (result == null) throw new IllegalArgumentException("null result");
            orderCount++;
            subtotal = Math.addExact(subtotal, result.original());
            saved = Math.addExact(saved, result.saved());
            for (Applied item : result.applied()) {
                long previous = perRule.getOrDefault(item.ruleId(), 0L);
                perRule.put(item.ruleId(), Math.addExact(previous, item.amount()));
            }
        }
        orders = orderCount;
        original = subtotal;
        savings = saved;
        savingsByRule = Collections.unmodifiableMap(perRule);
    }

    public int orders() { return orders; }
    public long original() { return original; }
    public long savings() { return savings; }
    public long collected() { return original - savings; }
    public Map<String, Long> savingsByRule() { return savingsByRule; }

    /** Return zero when no order used the requested rule. */
    public long savingsFor(String ruleId) {
        return savingsByRule.getOrDefault(ruleId, 0L);
    }
}

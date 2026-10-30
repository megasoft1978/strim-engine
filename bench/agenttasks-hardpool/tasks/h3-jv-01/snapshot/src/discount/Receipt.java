package discount;

/** Formats a compact receipt without changing evaluation state. */
public final class Receipt {
    private Receipt() { }

    public static String format(Result result) {
        StringBuilder out = new StringBuilder();
        out.append("subtotal:").append(result.original()).append('\n');
        for (Applied item : result.applied()) {
            out.append(item.ruleId()).append(":-").append(item.amount()).append('\n');
        }
        return out.append("total:").append(result.remaining()).toString();
    }
}

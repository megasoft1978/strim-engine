package discount;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Immutable calculation result. */
public final class Result {
    private final long original;
    private final long remaining;
    private final List<Applied> applied;

    public Result(long original, long remaining, List<Applied> applied) {
        this.original = original;
        this.remaining = remaining;
        this.applied = Collections.unmodifiableList(new ArrayList<>(applied));
    }

    public long original() { return original; }
    public long remaining() { return remaining; }
    public long saved() { return original - remaining; }
    public List<Applied> applied() { return applied; }
}

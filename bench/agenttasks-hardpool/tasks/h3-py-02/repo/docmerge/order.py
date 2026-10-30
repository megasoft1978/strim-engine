"""Sequence helpers for reconciling section order."""


def merge_order(base, left, right, included):
    """Prefer the left ordering, unless only the right changed the order.

    New sections from the other branch are appended in their original order.
    Conflicts are reported separately by the merger.
    """
    common = set(base) & set(left) & set(right)
    base_common = tuple(k for k in base if k in common)
    left_common = tuple(k for k in left if k in common)
    right_common = tuple(k for k in right if k in common)
    primary, secondary = (right, left) if left_common == base_common and right_common != base_common else (left, right)
    result = []
    for key in (*primary, *secondary, *base):
        if key in included and key not in result:
            result.append(key)
    return tuple(result)

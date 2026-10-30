"""Three-way section merge, retaining a usable preview on conflicts."""
from .model import Conflict, Document, MergeResult
from .order import merge_order


def merge(base, left, right):
    old, a, b = base.by_key(), left.by_key(), right.by_key()
    resolved = {}
    conflicts = []
    for key in dict.fromkeys((*base.keys(), *left.keys(), *right.keys())):
        ancestor, lval, rval = old.get(key), a.get(key), b.get(key)
        if lval == rval:
            value = lval
        elif lval == ancestor:
            value = rval
        elif rval == ancestor:
            value = lval
        else:
            conflicts.append(Conflict(key, 'content', ancestor, lval, rval))
            value = lval
        if value is not None:
            resolved[key] = value
    order = merge_order(base.keys(), left.keys(), right.keys(), resolved)
    preamble = right.preamble if left.preamble == base.preamble else left.preamble
    return MergeResult(Document(tuple(resolved[k] for k in order), preamble), tuple(conflicts))

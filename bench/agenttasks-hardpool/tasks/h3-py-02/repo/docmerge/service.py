"""Facade for callers that store documents as text."""
from .merge import merge
from .parser import parse
from .render import render
from .report import summary


def merge_text(base, left, right):
    return merge(parse(base), parse(left), parse(right))


def preview(base, left, right):
    result = merge_text(base, left, right)
    return render(result.document), summary(result)

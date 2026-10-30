"""Document statistics for a review dashboard."""
from collections import Counter
import re

WORD = re.compile(r"[\w']+", re.UNICODE)


def word_count(document):
    return sum(len(WORD.findall(s.title)) + len(WORD.findall(s.body))
               for s in document.sections)


def section_sizes(document):
    return {s.key: len(WORD.findall(s.body)) for s in document.sections}


def vocabulary(document):
    counts = Counter()
    for section in document.sections:
        counts.update(word.casefold() for word in WORD.findall(section.title))
        counts.update(word.casefold() for word in WORD.findall(section.body))
    return counts


def longest(document):
    sizes = section_sizes(document)
    if not sizes:
        return None
    return max(document.sections, key=lambda section: sizes[section.key])

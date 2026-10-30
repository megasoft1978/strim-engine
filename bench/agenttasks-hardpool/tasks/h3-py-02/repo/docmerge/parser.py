"""Parse the deliberately small document format, preserving body text."""
import re
from .model import Document, Section

HEADER = re.compile(r'^# (.+) \{#([A-Za-z0-9_-]+)\}$')


def parse(text):
    sections = []
    preamble = []
    title = key = None
    body = []
    seen = set()
    for line in text.splitlines(keepends=True):
        match = HEADER.fullmatch(line.rstrip('\r\n'))
        if match:
            if key is not None:
                sections.append(Section(key, title, ''.join(body)))
            title, key = match.groups()
            if key in seen:
                raise ValueError('duplicate section key: ' + key)
            seen.add(key)
            body = []
        elif key is None:
            preamble.append(line)
        else:
            body.append(line)
    if key is not None:
        sections.append(Section(key, title, ''.join(body)))
    return Document(tuple(sections), ''.join(preamble))

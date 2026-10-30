"""Immutable operations for an editor working on a single document."""
from .model import Document, Section
from .validate import problems


def replace(document, key, *, title=None, body=None):
    sections = []
    found = False
    for section in document.sections:
        if section.key == key:
            found = True
            section = Section(key, section.title if title is None else title,
                              section.body if body is None else body)
        sections.append(section)
    if not found:
        raise KeyError(key)
    result = Document(tuple(sections), document.preamble)
    if problems(result):
        raise ValueError('invalid section')
    return result


def remove(document, key):
    if key not in document.by_key():
        raise KeyError(key)
    return Document(tuple(s for s in document.sections if s.key != key),
                    document.preamble)


def insert(document, section, before=None):
    if section.key in document.by_key():
        raise ValueError('duplicate key')
    sections = list(document.sections)
    if before is None:
        sections.append(section)
    else:
        keys = document.keys()
        if before not in keys:
            raise KeyError(before)
        sections.insert(keys.index(before), section)
    result = Document(tuple(sections), document.preamble)
    if problems(result):
        raise ValueError('invalid section')
    return result


def move(document, key, before=None):
    section = document.by_key().get(key)
    if section is None:
        raise KeyError(key)
    if key == before:
        return document
    return insert(remove(document, key), section, before)

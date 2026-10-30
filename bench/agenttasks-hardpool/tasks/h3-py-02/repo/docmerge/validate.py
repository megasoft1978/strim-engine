"""Validation for programmatically constructed documents."""
import re

KEY = re.compile(r'^[A-Za-z0-9_-]+$')


def problems(document):
    found = set()
    errors = []
    for section in document.sections:
        if not KEY.fullmatch(section.key):
            errors.append(f'invalid key: {section.key}')
        if section.key in found:
            errors.append(f'duplicate key: {section.key}')
        if not section.title or '\n' in section.title:
            errors.append(f'invalid title: {section.key}')
        found.add(section.key)
    return tuple(errors)

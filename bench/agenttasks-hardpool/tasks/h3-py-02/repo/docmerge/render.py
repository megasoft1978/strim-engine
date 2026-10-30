"""Serialize documents in the same format accepted by the parser."""


def render(document):
    chunks = [document.preamble]
    for section in document.sections:
        chunks.append(f'# {section.title} {{#{section.key}}}\n')
        chunks.append(section.body)
    return ''.join(chunks)

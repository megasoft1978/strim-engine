"""Value objects shared by parsing, reporting, and merging."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Section:
    key: str
    title: str
    body: str


@dataclass(frozen=True)
class Document:
    sections: tuple
    preamble: str = ""

    def by_key(self):
        return {section.key: section for section in self.sections}

    def keys(self):
        return tuple(section.key for section in self.sections)


@dataclass(frozen=True)
class Conflict:
    key: str
    reason: str
    base: Section | None
    left: Section | None
    right: Section | None


@dataclass(frozen=True)
class MergeResult:
    document: Document
    conflicts: tuple

    @property
    def clean(self):
        return not self.conflicts

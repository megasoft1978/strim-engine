"""Small structured document merge library."""
from .model import Document, Section, Conflict, MergeResult
from .parser import parse
from .render import render
from .merge import merge

__all__ = ['Document', 'Section', 'Conflict', 'MergeResult', 'parse', 'render', 'merge']

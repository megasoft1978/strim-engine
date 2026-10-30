"""Read and write portable journal exports for support and reconciliation."""
import csv
import io
import json

from .audit import AuditError, replay

FIELDS = ("sequence", "account", "event_id", "kind", "amount", "reference")


class ExportError(ValueError):
    """An export cannot be decoded or has an invalid journal."""


def _validate(entries):
    try:
        replay(entries)
    except (AuditError, KeyError, TypeError, ValueError) as error:
        raise ExportError("invalid journal") from error
    return entries


def _normalize(row):
    if set(row) != set(FIELDS):
        raise ExportError("unexpected fields")
    result = dict(row)
    for field in ("sequence", "amount"):
        value = result[field]
        if isinstance(value, str):
            if not value.isascii() or not value.isdecimal():
                raise ExportError("invalid integer")
            value = int(value)
        if type(value) is not int:
            raise ExportError("invalid integer")
        result[field] = value
    return result


def to_csv(entries):
    rows = [_normalize(entry) for entry in entries]
    _validate(rows)
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=FIELDS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def from_csv(text):
    if not isinstance(text, str):
        raise ExportError("CSV must be text")
    reader = csv.DictReader(io.StringIO(text, newline=""), strict=True)
    if reader.fieldnames != list(FIELDS):
        raise ExportError("invalid CSV header")
    try:
        rows = [_normalize(row) for row in reader]
    except (csv.Error, UnicodeError) as error:
        raise ExportError("invalid CSV") from error
    return _validate(rows)


def to_json(entries):
    rows = [_normalize(entry) for entry in entries]
    _validate(rows)
    return json.dumps({"version": 1, "entries": rows}, ensure_ascii=False,
                      separators=(",", ":"))


def from_json(text):
    try:
        document = json.loads(text)
    except (ValueError, TypeError) as error:
        raise ExportError("invalid JSON") from error
    if not isinstance(document, dict) or set(document) != {"version", "entries"}:
        raise ExportError("invalid envelope")
    if type(document["version"]) is not int or document["version"] != 1:
        raise ExportError("unsupported version")
    if not isinstance(document["entries"], list):
        raise ExportError("entries must be a list")
    rows = []
    for entry in document["entries"]:
        if not isinstance(entry, dict):
            raise ExportError("entry must be an object")
        rows.append(_normalize(entry))
    return _validate(rows)

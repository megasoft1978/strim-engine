"""Errors returned to callers of the settlement service."""


class InvalidEvent(ValueError):
    """An event is well formed but cannot be applied to the current account."""


class InvalidRecord(ValueError):
    """A caller supplied an invalid record or an unknown event kind."""

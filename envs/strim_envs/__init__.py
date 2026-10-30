"""Strim task environments; adapters have independent optional dependencies."""

# verifiers discovers taskset plugins via __all__. Resolve lazily so the core and
# OpenEnv adapter remain usable without installing the incompatible Prime extra.
__all__ = ['StrimTaskset']


def __getattr__(name):
    if name == 'StrimTaskset':
        from .prime import StrimTaskset
        return StrimTaskset
    raise AttributeError(name)

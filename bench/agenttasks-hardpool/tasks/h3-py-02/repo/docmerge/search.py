"""Simple case-insensitive document search for review tools."""


def search(document, query):
    needle = query.casefold()
    if not needle:
        return ()
    return tuple(s for s in document.sections
                 if needle in s.title.casefold() or needle in s.body.casefold())

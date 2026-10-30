# Section review

This standard-library library merges documents whose sections begin with
`# Title {#stable-id}`. Everything between headers is literal body text.
The key identifies a section even when its title changes. Duplicate keys are
invalid. `docmerge.service.preview` returns a renderable preview and a report;
callers should inspect conflicts before accepting that preview.

The merger resolves identical changes, one-sided changes, additions, and
removals. Its ordering policy prefers the changed branch's order when the
other branch kept the base order, otherwise the left order; sections present
only on the other side are appended. Conflicts retain the left value in the
preview, including a deletion, and carry all three versions for review.

Run `python3 -I -B -m unittest discover -s tests -t .` from this directory.

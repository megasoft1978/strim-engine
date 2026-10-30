# Fieldnote

Fieldnote validates submitted form values against composable schemas. Rules can be synchronous or asynchronous. Results contain ordered issues, with paths suitable for displaying messages beside nested fields. A form session keeps the most recently requested validation as its current result.

Run `tsc --noEmit -p . && node --test` with Node's TypeScript support and the TypeScript compiler installed locally. No packages are required.

A validation request resolves with its own result, even if a newer request has already completed. Subscribers and `current` represent only the latest request. The schema operates on the value supplied to each request; callers should treat values as immutable while validation is running.

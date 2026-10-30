# Inventory reservations

An in-memory inventory service for warehouses. Stock is received by SKU, held
for an order, and either shipped in parts or released. All operations take an
explicit clock time, allowing callers to replay activity deterministically.
The service uses only Ruby's standard library.

Quantities are positive integers. Available stock excludes active holds;
shipping decreases both on-hand stock and the outstanding hold. Expiration is
inclusive: a hold expiring at an instant is no longer active at that instant.
Times are ISO 8601 timestamps with offsets; different offsets can describe
the same instant. Release and expiration are idempotent. Audit events describe
actual transitions and snapshots returned to callers are detached copies.

Run `ruby -Ilib -Itest test/all_test.rb` from this directory.

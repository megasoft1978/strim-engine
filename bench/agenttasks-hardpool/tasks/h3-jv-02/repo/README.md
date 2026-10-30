# Order desk

An in-memory order command handler with an append-only journal and notification
outbox. Amounts are whole minor currency units. Deliveries are keyed per order;
identical retries have no side effects and conflicting reuse is rejected.

Orders start created. Payment is accepted once, shipping follows payment,
and cancellation is available only before payment. Paid or shipped orders can
be refunded in portions; a full refund ends the lifecycle. A partial refund
leaves the existing paid/shipped state intact. Rejected commands do not consume
keys or append events. This implementation is single-threaded and makes no
claims about durable storage or concurrent writers.

Run `./scripts/javatest.sh` with a local JDK 11 or later; no dependencies are
needed. The report reads the journal, while the outbox models asynchronous
notification dispatch. The tests are protected.

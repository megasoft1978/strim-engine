# Settlement service

An in-memory, single-consumer settlement service for payment holds. Records are
validated before they enter the journal. Credits add funds, reserves earmark
funds, and captures or releases consume a reserve. Amounts are integer cents.

The public API is `SettlementService.process(record)`, `account(name)` and
`journal(account=None)`. Record identifiers are supplied by the upstream
account and identify one delivery within that account. Successful deliveries
are idempotent; rejected deliveries can be retried. The `settlement.report`
module provides read-only summaries of journal records.

Run the suite with `python3 -I -B -m unittest discover -s tests -t .`.

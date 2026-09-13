# Recorded Ops customer and job context

`ops-review project.json` returns the current recorded context, complete link history, edit fingerprint and an explicit authority limitation. An imported snapshot is not authenticated business access, an approved estimate or an instruction to publish billing.

Native Ops offers explicit customer-only or customer/job selection from its current local store. Ambiguous IDs and unresolved customer relationships are excluded. The project records UUIDs, customer name/address and optional job title/site/service-location ID as a snapshot. It does not silently copy those values into proposal terms, refresh them from a remote account or change any Ops record.

Use `apply` with this operation after reading the current edit fingerprint:

```json
{
  "operation": "ops.context.update",
  "author": "Recorded reviewer",
  "reason": "Selected the existing job for this mechanical project",
  "expectedFingerprint": "copy the current value from ops-review",
  "context": {
    "version": 1,
    "customer": {
      "id": "10000000-0000-4000-8000-000000000001",
      "name": "Synthetic customer",
      "address": "Synthetic customer address"
    },
    "job": {
      "id": "20000000-0000-4000-8000-000000000001",
      "customerID": "10000000-0000-4000-8000-000000000001",
      "title": "Synthetic job",
      "siteAddress": "Synthetic site address",
      "serviceLocationID": null
    }
  }
}
```

These IDs are examples only, not live records. `context`, `customer` and `job` objects require exactly the documented keys; all IDs are valid UUID strings. `job: null` links a customer without a job. `context: null` removes an existing link. Omission is rejected, not interpreted as removal. Job customerID must equal customer.id. Blank addresses/titles mean not recorded and are not inferred from the customer billing address.

Every successful save appends author, timestamp, reason and complete before/after snapshots, including removals. Same-value reaffirmation still advances the edit token. Stale tokens, invalid joins and malformed records fail without applying changes. QA reopens; commercial fields and takeoff prices stay unchanged. History consistency checks do not constitute cryptographic authenticity or authenticated identity.

Package and self-contained JSON exports preserve the link/history. Native edits remain in the current document until saved/exported. Customer/job synchronization, catalog pricing mapping and authenticated billing publication remain separate unfinished workflows.

"""Complete role-filtered content preparation for the pinned 32-kind workspace.

Field projections are distinct from owner models. This prepares read-only
content; it never activates a staff store, grants a lease or executes commands.
"""
from __future__ import annotations

import copy

try:
    from Backend import staff_workspace_contract as contract, staff_workspace_selection as selection
    from Backend import staff_workspace_field_policy as policy, staff_workspace_structured as structured
    from Backend import staff_workspace_discriminators as discriminators
    from Backend import staff_billing_projection as billing
except ModuleNotFoundError:
    import staff_workspace_contract as contract
    import staff_workspace_selection as selection
    import staff_workspace_field_policy as policy
    import staff_workspace_structured as structured
    import staff_workspace_discriminators as discriminators
    import staff_billing_projection as billing

SCHEMA = "staff-workspace-content-v1"
STRUCTURED_SCHEMA = "staff-operational-evidence-v1"
MAX_BYTES = 64 * 1024 * 1024


def prepare(graph, index, metadata, email):
    policies = policy.policies()
    role = metadata["memberRole"]
    if metadata["projectionPolicy"] != selection.sharing.POLICIES.get(role):
        raise selection.failure("sharing_changed")
    selection.sharing.scope(metadata)
    selection.sharing.identifier(metadata["replicaID"])
    contract.integer(metadata["sourceSequence"], 1)
    for records in graph.live.values():
        if any(any(record[name] != metadata[name] for name in ("companyID", "environment", "replicaID")) for record in records.values()):
            raise selection.failure("source_changed")
    # Never grant access from a caller-supplied record list or local user role.
    expected = graph.index(role, email)
    if index != expected:
        raise selection.failure("sharing_changed")
    discriminators.validate(graph)
    data = structured.Structured(graph).validate()
    billing_view = billing.prepare(graph, index, metadata)
    billing_documents = {(doc["kind"], doc["id"].lower()): doc for doc in billing_view["documents"]}
    selected = {(entry["kind"], entry["id"]) for entry in index}
    result = {key: metadata[key] for key in ("companyID", "environment", "replicaID", "membershipID", "memberRevision", "memberRole", "shareRevision", "projectionPolicy", "sourceSequence")}
    result.update(schema=SCHEMA, sourceSchema=contract.SCHEMA_VERSION, sourceSchemaDigest=contract.SCHEMA_DIGEST,
                  fieldPolicy=policy.VERSION, discriminatorSchema=discriminators.VERSION, structuredSchema=STRUCTURED_SCHEMA, billingSchema=billing.SCHEMA,
                  coverage=sorted(contract.SPECS), records=[])
    for entry in index:
        kind, identity = entry["kind"], entry["id"]
        if kind in ("invoice", "estimate"):
            body = {"billing": {"_0": billing_documents[(kind, identity)]}}
        else:
            record = graph.live[kind][identity]
            owned = policy.own(graph, record, email)
            fields, unavailable, evidence = {}, {}, {}
            for name, rule in policies[kind].items():
                if not policy.allows(rule, role, owned):
                    unavailable[name] = "serviceOnly" if rule == "serviceOnly" else "roleRestricted"
                elif name in structured.JSON_FIELDS.get(kind, set()):
                    evidence[name] = structured.disclose(kind, name, data.values[(kind, identity, name)], role, email, selected)
                else:
                    # A JSON field never silently falls through to raw text.
                    if name.endswith("JSON"):
                        raise selection.failure("schema_changed")
                    fields[name] = copy.deepcopy(record["fields"][name])
            body = {"operational": {"_0": dict(fields=fields, unavailableFields=unavailable, structuredFields=evidence)}}
        result["records"].append(dict(entry, body=body))
    if len(contract.wire(result).encode()) > MAX_BYTES:
        raise selection.failure("source_capacity")
    return result

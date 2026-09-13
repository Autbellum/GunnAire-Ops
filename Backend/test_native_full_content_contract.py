"""Pin the real server selection and content wires consumed by the native flow."""
import json
from pathlib import Path
import unittest

from Backend import staff_workspace_contract as contract, staff_workspace_selection as selection
from Backend import staff_workspace_selections as selections, staff_workspace_delivery as delivery
from Backend import staff_workspace_projection as projection, cloudkit_staff_shares as shares
from Backend import test_staff_workspace_projection as fixtures, test_staff_billing_delivery as billing
from Backend import test_staff_workspace_selections as indexes


def interop():
    records = fixtures.rich_records()
    graph = selection.Graph(records)
    operation = "a1000000-0000-4000-8000-000000000077"
    roles = {}
    for role in shares.POLICIES:
        scope = (billing.COMPANY, "development", billing.REPLICA, contract.SCHEMA_VERSION)
        share = dict(id=billing.metadata()["membershipID"], member_revision="a" * 64, member_role=role,
                     projection_policy=shares.POLICIES[role], revision=4)
        snapshot = dict(**selections.StaffWorkspaceSelections.metadata(scope, share), operationID=operation,
                        sourceSequence=1, records=graph.index(role, indexes.EMAIL))
        selector = selections.StaffWorkspaceSelections.__new__(selections.StaffWorkspaceSelections)
        server = delivery.StaffWorkspaceDelivery.__new__(delivery.StaffWorkspaceDelivery)
        server.selection = selector
        raw = contract.wire(projection.prepare(graph, snapshot["records"], snapshot, indexes.EMAIL)).encode("utf-8")
        roles[role] = dict(selectionRequest=dict(companyID=scope[0], environment=scope[1], replicaID=scope[2],
            operationID=operation, expectedSourceSequence=1, expectedShareRevision=4, sourceSchemaDigest=contract.SCHEMA_DIGEST),
            selectionReceipt=selector.receipt(snapshot, 1), index=snapshot["records"],
            contentReceipt=server.receipt(raw, snapshot, 1), payloadUtf8=raw.decode("utf-8"))
    return dict(source=sorted(records, key=lambda r: (r["kind"], r["id"])), roles=roles)


class NativeFullContentContractTests(unittest.TestCase):
    def test_native_vector_is_the_actual_current_server_selection_and_full_content_for_all_roles(self):
        path = Path(__file__).resolve().parents[1] / "GunnAire OpsTests" / "NativeFullContentInterop.json"
        self.assertEqual(json.loads(path.read_text()), interop())


if __name__ == "__main__":
    unittest.main()

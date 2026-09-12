"""Immutable full-workspace CloudKit sealing and staff key release.

Owner Admin prepares/reads seals at `/content/cloud-seal`. Staff (and Admin)
may GET an already-prepared key at `/content/cloud-key`. Keys never enter
CloudKit or audit metadata. GET never creates keys; a missing/corrupt
previously committed key is retained as an explicit storage failure.
"""
from __future__ import annotations

import base64
import secrets
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

try:
    from Backend import staff_workspace_delivery as delivery
except ModuleNotFoundError:
    import staff_workspace_delivery as delivery

contract, sharing = delivery.contract, delivery.sharing
SCHEMA = "staff-workspace-cloud-seal-v1"


def aad(receipt):
    fields = "companyID environment replicaID membershipID memberRevision memberRole shareRevision projectionPolicy selectionID sourceSequence selectionSHA256 contentSHA256"
    return ("gunnaire-full-workspace-cloud-seal-v1\n" + "\n".join(str(receipt[k]) for k in fields.split())).encode()


def sealed_bytes(raw, receipt, key, nonce):
    return nonce + AESGCM(key).encrypt(nonce, raw, aad(receipt))


def material(encoded, size):
    if type(encoded) is not str or len(encoded) != 4 * ((size + 2) // 3):
        raise ValueError()
    value = base64.b64decode(encoded, validate=True)
    if len(value) != size or base64.b64encode(value).decode() != encoded:
        raise ValueError()
    return value


class StaffWorkspaceCloud(delivery.StaffWorkspaceDelivery):
    def seal(self, session_id, share_id, operation, payload, *, prepare=False):
        contract.exact(payload, delivery.SCOPE_FIELDS + (" contentSchema" if prepare else ""))
        if prepare and payload["contentSchema"] != delivery.projection.SCHEMA:
            raise sharing.fail("schema_changed", "Use the supported full-workspace content schema.", 409)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, snapshot, sequence = self.authority(connection, session_id, share_id, operation, payload)
            raw = self.original(connection, operation, snapshot)
            if raw is None:
                raise sharing.fail("content_not_prepared", "Prepare the original full content before sealing it.", 404)
            # Reassignment/deletion, source advance, changed role or revoked
            # sharing must block BOTH creation and release of an existing key.
            if sequence != snapshot["sourceSequence"]:
                raise sharing.fail("source_changed", "Refresh full company data before publishing this snapshot.", 409)
            receipt = self.receipt(raw, snapshot, sequence)
            row = connection.execute("SELECT * FROM staff_workspace_cloud_seals WHERE selection_id=?", (operation,)).fetchone()
            marker = connection.execute("SELECT seal_sha256 FROM staff_workspace_projections WHERE selection_id=?", (operation,)).fetchone()[0]
            if row is None:
                if marker is not None:
                    raise self.source.unavailable()
                if not prepare:
                    raise sharing.fail("seal_not_prepared", "Prepare the original CloudKit seal first.", 404)
                key, nonce = AESGCM.generate_key(bit_length=256), secrets.token_bytes(12)
                sealed = sealed_bytes(raw, receipt, key, nonce)
                saved = dict(schema=SCHEMA, authenticatedScope=aad(receipt).decode(),
                             keyBase64=base64.b64encode(key).decode(), nonceBase64=base64.b64encode(nonce).decode(),
                             sealedSHA256=delivery.digest(sealed))
                encrypted = self.source.encode(saved)
                connection.execute("INSERT INTO staff_workspace_cloud_seals VALUES (?,?)", (operation, encrypted))
                connection.execute("UPDATE staff_workspace_projections SET seal_sha256=? WHERE selection_id=?",
                                   (saved["sealedSHA256"], operation))
            else:
                saved = self.source.decode(row["ciphertext"])
                try:
                    contract.exact(saved, "schema authenticatedScope keyBase64 nonceBase64 sealedSHA256")
                    if saved["schema"] != SCHEMA or saved["authenticatedScope"] != aad(receipt).decode():
                        raise ValueError()
                    key, nonce = material(saved["keyBase64"], 32), material(saved["nonceBase64"], 12)
                    sealed = sealed_bytes(raw, receipt, key, nonce)
                    if delivery.digest(sealed) != saved["sealedSHA256"] or marker != saved["sealedSHA256"]:
                        raise ValueError()
                except (ValueError, TypeError, KeyError, sharing.AttemptError):
                    raise self.source.unavailable() from None
            self.shares.audit(actor["email"], "prepare-full-cloud-seal" if prepare else "read-full-cloud-seal",
                              "staff-workspace-selection", operation, connection=connection)
            return dict(schema=SCHEMA, content=receipt, sealedSHA256=saved["sealedSHA256"], sealedBytes=len(sealed),
                        keyBase64=saved["keyBase64"], nonceBase64=saved["nonceBase64"])

    def release_key(self, session_id, share_id, operation, query):
        """GET-only release of an already-prepared seal key.

        Current accepted/business-eligible share members and owner Admin may
        obtain keyBase64/nonceBase64. Never creates keys, never returns sealed
        content bytes, and never routes through Admin-only owner source.scope.
        """
        contract.exact(query, delivery.SCOPE_FIELDS)
        sharing.identifier(operation)
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            actor, scope, share = self.selection.member_authority(connection, session_id, share_id, query)
            row = connection.execute(
                "SELECT * FROM staff_workspace_selections WHERE id=? AND share_id=?",
                (operation, share_id)).fetchone()
            snapshot = self.selection.shared_original(row, scope, share)
            sequence = self.source.sequence(connection, scope)
            self.selection.receipt(snapshot, sequence)  # Detect source-head rollback.
            raw = self.original(connection, operation, snapshot)
            if raw is None:
                raise sharing.fail("content_not_prepared", "Prepare the original full content before sealing it.", 404)
            # Reassignment/deletion, source advance, changed role or revoked
            # sharing must block release of an existing key without replacing it.
            if sequence != snapshot["sourceSequence"]:
                raise sharing.fail("source_changed", "Refresh full company data before publishing this snapshot.", 409)
            receipt = self.receipt(raw, snapshot, sequence)
            seal_row = connection.execute(
                "SELECT * FROM staff_workspace_cloud_seals WHERE selection_id=?", (operation,)).fetchone()
            marker = connection.execute(
                "SELECT seal_sha256 FROM staff_workspace_projections WHERE selection_id=?", (operation,)).fetchone()[0]
            if seal_row is None:
                if marker is not None:
                    raise self.source.unavailable()
                raise sharing.fail("seal_not_prepared", "Prepare the original CloudKit seal first.", 404)
            saved = self.source.decode(seal_row["ciphertext"])
            try:
                contract.exact(saved, "schema authenticatedScope keyBase64 nonceBase64 sealedSHA256")
                if saved["schema"] != SCHEMA or saved["authenticatedScope"] != aad(receipt).decode():
                    raise ValueError()
                key, nonce = material(saved["keyBase64"], 32), material(saved["nonceBase64"], 12)
                sealed = sealed_bytes(raw, receipt, key, nonce)
                if delivery.digest(sealed) != saved["sealedSHA256"] or marker != saved["sealedSHA256"]:
                    raise ValueError()
            except (ValueError, TypeError, KeyError, sharing.AttemptError):
                raise self.source.unavailable() from None
            self.shares.audit(actor["email"], "read-full-cloud-key", "staff-workspace-selection", operation,
                              connection=connection)
            # Same wire schema as owner seal prepare/read — key release, not prepare.
            return dict(schema=SCHEMA, content=receipt, sealedSHA256=saved["sealedSHA256"], sealedBytes=len(sealed),
                        keyBase64=saved["keyBase64"], nonceBase64=saved["nonceBase64"])

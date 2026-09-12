"""Read-only, author-only outcomes for immutable staff submissions.

Never return an owner's current field, claim, store ID, or resolution request.
Published is historical owner-source confirmation, not QBO/CloudKit convergence.
"""
try:
    from Backend import staff_owner_field_edits as edits
except ModuleNotFoundError:
    import staff_owner_field_edits as edits

SCHEMA = "staff-field-updates-v1"
PAGE_SIZE = 8
contract, sharing = edits.contract, edits.sharing


class StaffWorkspaceFieldUpdates(edits.StaffOwnerFieldEdits):
    def entry(self, connection, scope, share, actor, command_id):
        row, saved = self.command(connection, scope, command_id)
        if row["share_id"] != share["id"] or row["actor_email"] != actor["email"]:
            raise sharing.fail("update_not_found", "This submission is not available to the current staff member.", 404)
        original = connection.execute("SELECT * FROM staff_workspace_selections WHERE id=?", (row["selection_id"],)).fetchone()
        snapshot = self.selection.shared_original(original, scope, share)
        request = saved["request"]
        if (request["sourceSequence"] != snapshot["sourceSequence"] or not any(
                r["kind"] == request["recordKind"] and r["id"] == request["recordID"] and
                r["revision"] == request["expectedRevision"] for r in snapshot["records"])):
            raise self.source.unavailable()
        application = self.application(connection, command_id)
        resolution = self.resolution(connection, scope, command_id)
        state, decided_at = "awaitingOffice", ""
        if resolution:
            state, decided_at = "keptOffice", resolution["receipt"]["resolvedAt"]
        elif application and application["receipt"]["state"] == "published":
            state, decided_at = "appliedToOffice", application["receipt"]["publishedAt"]
        # Deliberately construct a closed response. Do not forward owner detail().
        return dict(request=request, receipt=saved["receipt"], state=state, decidedAt=decided_at)

    def read_updates(self, session_id, share_id, command_id, query):
        contract.exact(query, edits.SCOPE + (" after" if command_id is None and "after" in query else ""))
        if command_id is not None:
            sharing.identifier(command_id)
        after = sharing.identifier(query["after"]) if "after" in query else ""
        with self.shares.database() as connection:
            # One read snapshot: authority, original and decision must agree.
            connection.execute("BEGIN")
            actor, scope, share = self.selection.member_authority(connection, session_id, share_id, query)
            if (actor["email"] != share["member_email"] or
                    not edits.commands.field_policy.allows("operations", share["member_role"], False)):
                raise sharing.fail("sharing_forbidden", "Only the submitting staff member can read these updates.", 403)
            if command_id is None:
                rows = connection.execute("""SELECT c.command_id FROM staff_workspace_commands c
                    JOIN staff_workspace_selections s ON s.id=c.selection_id AND s.share_id=c.share_id
                    WHERE c.share_id=? AND c.actor_email=? AND s.company_id=? AND s.environment=? AND s.replica_id=?
                    AND c.command_id>? ORDER BY c.command_id LIMIT ?""",
                    (share_id, actor["email"], *scope[:3], after, PAGE_SIZE + 1)).fetchall()
                ids = [row["command_id"] for row in rows[:PAGE_SIZE]]
                cursor = ids[-1] if len(rows) > PAGE_SIZE else ""
            else:
                ids, cursor = [command_id], ""
            entries = [self.entry(connection, scope, share, actor, identifier) for identifier in ids]
            return dict(schema=SCHEMA, companyID=scope[0], environment=scope[1], replicaID=scope[2],
                        shareID=share_id, entries=entries, nextCursor=cursor)

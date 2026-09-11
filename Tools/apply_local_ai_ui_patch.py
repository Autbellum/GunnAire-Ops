#!/usr/bin/env python3
"""Apply the reviewed local-AI entry points to existing Swift views.

This is intentionally idempotent and anchor-checked. It edits only the Command
Center and administrator Settings views and never changes business calculations.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def patch_dashboard() -> bool:
    path = ROOT / "GunnAire Ops/OperationsDashboardView.swift"
    text = path.read_text(encoding="utf-8")
    if "CommandCenterLocalAIButton" in text:
        return False

    state_anchor = "    @State private var showingTimeOffRequests = false\n"
    text = replace_once(
        text,
        state_anchor,
        state_anchor + "    @State private var showingLocalAIWorkspace = false\n",
        "dashboard state",
    )

    toolbar_anchor = '''                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCommandPalette = true
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("CommandCenterToolbarFindButton")
                    .tint(Color.brandGold)
                }
'''
    toolbar_addition = toolbar_anchor + '''                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingLocalAIWorkspace = true
                    } label: {
                        Label("Local AI", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("CommandCenterLocalAIButton")
                    .tint(Color.brandGold)
                    .disabled(!GunnAireBackendService.isConfigured)
                }
'''
    text = replace_once(text, toolbar_anchor, toolbar_addition, "dashboard toolbar")

    sheet_anchor = '''            .sheet(isPresented: $showingCommandPalette) {
                OperationsCommandPalette(
                    customers: searchableCustomers,
                    serviceCalls: dashboardServiceCalls,
                    invoices: dashboardInvoices,
                    estimates: dashboardEstimates,
                    payments: dashboardPayments,
                    access: operationsAccess
                )
                    .tint(Color.brandGold)
            }
'''
    sheet_addition = sheet_anchor + '''            .sheet(isPresented: $showingLocalAIWorkspace) {
                GunnAireLocalAIWorkspace(
                    snapshot: suiteSnapshot,
                    role: currentUserRole,
                    canViewFinancials: canViewFinancials
                )
            }
'''
    text = replace_once(text, sheet_anchor, sheet_addition, "dashboard sheet")

    required = (
        "showingLocalAIWorkspace",
        "CommandCenterLocalAIButton",
        "GunnAireLocalAIWorkspace(",
        "canViewFinancials: canViewFinancials",
    )
    if not all(value in text for value in required):
        raise SystemExit("dashboard postcondition failed")
    path.write_text(text, encoding="utf-8")
    return True


def patch_settings() -> bool:
    path = ROOT / "GunnAire Ops/SettingsView.swift"
    text = path.read_text(encoding="utf-8")
    if "GunnAireLocalAIReadinessSection()" in text:
        return False
    anchor = '                        Section("App Loading Video") {\n'
    text = replace_once(
        text,
        anchor,
        "                        GunnAireLocalAIReadinessSection()\n\n" + anchor,
        "settings local AI section",
    )
    if text.count("GunnAireLocalAIReadinessSection()") != 1:
        raise SystemExit("settings postcondition failed")
    path.write_text(text, encoding="utf-8")
    return True


def main() -> None:
    dashboard = patch_dashboard()
    settings = patch_settings()
    changed = [name for name, value in (("dashboard", dashboard), ("settings", settings)) if value]
    print("Patched: " + (", ".join(changed) if changed else "already applied"))


if __name__ == "__main__":
    main()

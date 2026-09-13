# GunnAire Ops Codex plugin

Repository source for the mechanical takeoff, calculation, RFI and change-order skills. The `.codex-plugin/plugin.json` manifest and `skills/` directory are portable. This directory is independent of the machine's installed plugin cache.

## Run against this checkout

From the repository root:

```sh
python3 Plugins/gunnaire-ops/scripts/loadsight.py validate LoadSight/Tests/LoadSightKitTests/Fixtures/Blank_Project.json
python3 -m unittest discover -s Plugins/gunnaire-ops/tests -v
```

The wrapper finds the sibling `LoadSight/` package. For an installed or copied plugin, set `LOADSIGHT_WORKSPACE` to the package directory or supply `--workspace /absolute/path/to/LoadSight`. Swift uses the package's normal build directory, avoiding a machine-specific shared scratch path.

See `references/project-edits.md` for structured edit operations and the other reference files for engineering and Word exports. `apply`, `rfi-docx` and `co-docx` require a new output path and reject existing files or symlinks. Export native packages to self-contained JSON before passing them to this wrapper.

This plugin does not publish invoices, send messages, authenticate approvals or supply complete ACCA/code methods. See `LoadSight/BUILD_STATUS.md` in the repository root for verified scope. Repository version 0.1.0 is source packaging; it does not replace an installed personal plugin automatically.

Recorded customer/job context is available through `ops-review` and `ops.context.update`; see `references/ops-project-context.md`. These are local snapshots with authored history, not authenticated billing actions.

Catalog material snapshots are available through `catalog-review` and `catalog.material.update`. See [catalog-material-mapping.md](references/catalog-material-mapping.md) for exact fields, explicit USD/unit evidence, unknown costs, history, removal and stale-edit protection. No live catalog fetch or accounting publication is performed.

`xlsx project.json --output new-workbook.xlsx` generates the native five-tab snapshot, including material costs and complete catalog history. Existing outputs are never replaced.

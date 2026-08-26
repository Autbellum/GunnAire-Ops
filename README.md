# GunnAire Ops

GunnAire Ops is the native iPad, iPhone, and Mac Catalyst HVAC field-service
suite in [`GunnAire Ops.xcodeproj`](GunnAire%20Ops.xcodeproj).

## Backend deployment

The canonical shared-service implementation, configuration guide, and local
test commands are in [`Backend/`](Backend/README.md). The repository-root
`gunnaire_backend.py` and `requirements.txt` files are deliberately small
Render compatibility shims:

```sh
python3 -m pip install -r requirements.txt
python3 gunnaire_backend.py
```

Do not copy service code into the root launcher. Keeping one implementation in
`Backend/gunnaire_backend.py` ensures Render uses the same encrypted,
realm-bound QuickBooks OAuth flow and role policies covered by backend tests.

## Product and release evidence

- [`CAPABILITY_AUDIT.md`](CAPABILITY_AUDIT.md) — field-service benchmark and
  implemented workflow inventory.
- [`COMPLETION_EVIDENCE_MATRIX.md`](COMPLETION_EVIDENCE_MATRIX.md) — verified
  product requirements and external gates.
- [`RELEASE_READINESS.md`](RELEASE_READINESS.md) — Apple, backend, OAuth, and
  physical-device release requirements.
- [`AppStoreAssets/`](AppStoreAssets/) — verified App Store screenshot assets.

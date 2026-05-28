# GunnAire Ops Mac Studio Backend

This is a small local backend for sharing app users, roles, and uploaded field receipts across iPads.

## Start It On The Mac Studio

```sh
cd "/Users/gunnaire/Library/Mobile Documents/com~apple~CloudDocs/GunnAire-Ops/Backend"
export GUNNAIRE_BACKEND_API_TOKEN="replace-with-a-long-random-token"
export GUNNAIRE_BACKEND_PORT=8787
python3 gunnaire_backend.py
```

Use the Mac Studio LAN name or IP address in the iOS app config:

```xcconfig
GUNNAIRE_BACKEND_BASE_URL = http://macstudio.local:8787
GUNNAIRE_BACKEND_API_TOKEN = replace-with-a-long-random-token
```

The token in the backend environment and the app config must match.

## What It Stores

- Approved GunnAire app users and roles.
- Active/inactive access state.
- Uploaded receipt/document files under `Backend/storage`.
- Backend metadata in `gunnaire_backend.sqlite3`.

The primary admin `eric.gunn@gunnaire.com` is seeded automatically and cannot be deactivated.

## Quick Checks

```sh
curl http://macstudio.local:8787/health
curl -H "Authorization: Bearer replace-with-a-long-random-token" http://macstudio.local:8787/api/users
```

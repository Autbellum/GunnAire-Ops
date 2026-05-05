# OAuth Callback Bridge (QBO + Google)

This app uses provider-registered HTTPS redirect URIs, then expects a final app callback using the custom scheme `gunnaireops://`.

## App Expectations

Environment variables should be set as:

- `QB_REDIRECT_URI=https://gunnaire.com/wp-json/ga/v1/qbo/oauth/callback`
- `QB_CALLBACK_SCHEME=gunnaireops`
- `GOOGLE_REDIRECT_URI=https://gunnaire.com/wp-json/ga/v1/sso/google/callback`
- `GOOGLE_CALLBACK_SCHEME=gunnaireops`

## Required Server Behavior

After your web callback endpoint receives OAuth params, redirect to the app scheme:

- QuickBooks:
  - From: `/wp-json/ga/v1/qbo/oauth/callback?code=...&state=...&realmId=...`
  - To: `gunnaireops://oauth/qbo?code=...&state=...&realmId=...`

- Google:
  - From: `/wp-json/ga/v1/sso/google/callback?code=...&state=...`
  - To: `gunnaireops://oauth/google?code=...&state=...`

## Notes

- Preserve `code` and `state` exactly.
- Preserve `realmId` for QuickBooks.
- Use an HTTP 302/307 redirect.
- If callback contains `error` and `error_description`, forward those query params to the app scheme too.

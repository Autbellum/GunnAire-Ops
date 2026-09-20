"""Minimal transactional email sending via Postmark's HTTP API.

This is deliberately separate from `google_mail.py`: that module sends mail
as a signed-in staff member's own Gmail account (OAuth), which has no bearing
on system-generated notices like "a customer submitted a request." Using a
dedicated transactional provider means these notices go out even when no
staff member is signed in or has Gmail connected, and keeps staff mailboxes
out of an automated send path.

No SDK dependency: a single HTTPS POST via urllib, matching the stdlib-only
style of the rest of this backend.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request

POSTMARK_ENDPOINT = "https://api.postmarkapp.com/email"


def send_transactional_email(
    *,
    api_key: str,
    from_address: str,
    to_address: str,
    subject: str,
    text_body: str,
    request_factory=urllib.request.Request,
    opener=urllib.request.urlopen,
) -> bool:
    """Best-effort send. Returns False (never raises) on any failure so a missing
    or misconfigured provider never blocks the caller's own request from succeeding.
    """
    if not api_key or not from_address or not to_address or not subject or not text_body:
        return False
    body = json.dumps(
        {
            "From": from_address,
            "To": to_address,
            "Subject": subject,
            "TextBody": text_body,
            "MessageStream": "outbound",
        }
    ).encode("utf-8")
    request = request_factory(
        POSTMARK_ENDPOINT,
        data=body,
        method="POST",
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Postmark-Server-Token": api_key,
        },
    )
    try:
        with opener(request, timeout=10) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, TimeoutError, ValueError):
        return False

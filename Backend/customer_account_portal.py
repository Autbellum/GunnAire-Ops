"""Static HTML/CSS/JS for the customer self-service account portal.

Kept out of gunnaire_backend.py to avoid growing that file further; served
as a single page (client-side "routes" itself between sign-in and dashboard
based on local session state and the ?token= query parameter used by the
magic-link email). No build step, no framework: plain fetch() calls to the
same-origin /api/customer/* endpoints defined in gunnaire_backend.py.
"""
from __future__ import annotations

PORTAL_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GunnAire Customer Account</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    margin: 0; padding: 0; background: #f4f5f7; color: #1c1c1e;
  }
  @media (prefers-color-scheme: dark) { body { background: #111214; color: #f2f2f3; } }
  header {
    padding: 20px 16px; background: #0b3d2e; color: #fff;
    font-size: 1.2rem; font-weight: 600;
  }
  main { max-width: 480px; margin: 0 auto; padding: 20px 16px 60px; }
  .card {
    background: #fff; border-radius: 12px; padding: 20px; margin-bottom: 16px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.08);
  }
  @media (prefers-color-scheme: dark) { .card { background: #1c1d20; } }
  h2 { margin-top: 0; font-size: 1.05rem; }
  label { display: block; margin: 12px 0 4px; font-size: 0.85rem; font-weight: 600; }
  input, select, textarea {
    width: 100%; box-sizing: border-box; padding: 10px; border-radius: 8px;
    border: 1px solid #ccc; font-size: 1rem; background: transparent; color: inherit;
  }
  textarea { min-height: 80px; resize: vertical; }
  button {
    margin-top: 16px; width: 100%; padding: 12px; border: none; border-radius: 8px;
    background: #0b3d2e; color: #fff; font-size: 1rem; font-weight: 600; cursor: pointer;
  }
  button:disabled { opacity: 0.5; cursor: default; }
  button.secondary { background: transparent; color: #0b3d2e; border: 1px solid #0b3d2e; }
  @media (prefers-color-scheme: dark) { button.secondary { color: #6fd6ab; border-color: #6fd6ab; } }
  .message { font-size: 0.9rem; margin-top: 10px; }
  .message.error { color: #b3261e; }
  .message.success { color: #1b7a3c; }
  .invoice-row { display: flex; justify-content: space-between; align-items: center; padding: 8px 0; border-top: 1px solid rgba(0,0,0,0.08); }
  .invoice-row:first-child { border-top: none; }
  .invoice-row a { color: #0b3d2e; font-weight: 600; text-decoration: none; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<header>GunnAire Customer Account</header>
<main>

  <section id="signInView" class="card">
    <h2>Sign in</h2>
    <p>Enter your name and email. We'll send you a secure sign-in link — no password needed.</p>
    <label for="signInName">Name</label>
    <input id="signInName" autocomplete="name">
    <label for="signInEmail">Email</label>
    <input id="signInEmail" type="email" autocomplete="email">
    <label for="signInPhone">Phone (optional)</label>
    <input id="signInPhone" type="tel" autocomplete="tel">
    <button id="signInButton">Send Sign-In Link</button>
    <div id="signInMessage" class="message" hidden></div>
  </section>

  <section id="verifyingView" class="card" hidden>
    <h2>Signing you in…</h2>
    <div id="verifyMessage" class="message"></div>
  </section>

  <section id="dashboardView" hidden>
    <div class="card">
      <h2 id="welcomeHeading">Welcome</h2>
      <div id="accountStatus" class="message"></div>
      <button id="signOutButton" class="secondary">Sign Out</button>
    </div>

    <div class="card">
      <h2>Invoices</h2>
      <div id="invoicesList">Loading…</div>
    </div>

    <div class="card">
      <h2>Request Service, Maintenance, or an Estimate</h2>
      <label for="requestType">Type</label>
      <select id="requestType">
        <option value="service">Service</option>
        <option value="maintenance">Maintenance</option>
        <option value="estimate">Estimate</option>
        <option value="install">Install</option>
      </select>
      <label for="requestUrgency">Urgency</label>
      <select id="requestUrgency">
        <option value="normal">Normal</option>
        <option value="priority">Priority</option>
        <option value="emergency">Emergency</option>
      </select>
      <label for="requestPreferredDate">Preferred date (optional)</label>
      <input id="requestPreferredDate" type="date">
      <label for="requestAddress">Service address (optional)</label>
      <input id="requestAddress">
      <label for="requestSummary">What do you need?</label>
      <textarea id="requestSummary" placeholder="Tell us what's going on and any scheduling preferences."></textarea>
      <button id="requestSubmitButton">Submit Request</button>
      <div id="requestMessage" class="message" hidden></div>
      <p style="font-size:0.8rem;color:#888;">Submitting a request does not book an appointment. Our team will contact you to confirm a time or offer alternatives.</p>
    </div>
  </section>

</main>
<script>
(function () {
  "use strict";
  var SESSION_KEY = "gunnaireCustomerSessionToken";

  function el(id) { return document.getElementById(id); }
  function show(id) { el(id).hidden = false; }
  function hide(id) { el(id).hidden = true; }
  function setMessage(id, text, kind) {
    var node = el(id);
    node.textContent = text;
    node.className = "message" + (kind ? " " + kind : "");
    node.hidden = !text;
  }

  function api(path, options) {
    options = options || {};
    var headers = options.headers || {};
    headers["Content-Type"] = "application/json";
    var token = localStorage.getItem(SESSION_KEY);
    if (token && options.authenticated !== false) {
      headers["Authorization"] = "Bearer " + token;
    }
    return fetch(path, {
      method: options.method || "GET",
      headers: headers,
      body: options.body ? JSON.stringify(options.body) : undefined,
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (data) {
        if (!response.ok) {
          var error = new Error(data.error || ("Request failed (" + response.status + ")"));
          error.status = response.status;
          throw error;
        }
        return data;
      });
    });
  }

  function showSignIn() {
    hide("verifyingView"); hide("dashboardView"); show("signInView");
  }

  function showDashboard(account) {
    hide("signInView"); hide("verifyingView"); show("dashboardView");
    el("welcomeHeading").textContent = "Welcome, " + account.name;
    setMessage(
      "accountStatus",
      account.linkStatus === "linked"
        ? "Your account is linked to your GunnAire customer record."
        : "Your account is pending review by our team. Some information may not be available yet.",
      account.linkStatus === "linked" ? "success" : ""
    );
    loadInvoices();
  }

  function loadInvoices() {
    var list = el("invoicesList");
    list.textContent = "Loading…";
    api("/api/customer/invoices").then(function (data) {
      var invoices = data.invoices || [];
      if (invoices.length === 0) {
        list.textContent = "No invoices on file.";
        return;
      }
      list.innerHTML = "";
      invoices.forEach(function (invoice) {
        var row = document.createElement("div");
        row.className = "invoice-row";
        var label = document.createElement("span");
        label.textContent = (invoice.docNumber ? "Invoice " + invoice.docNumber : "Invoice") +
          (invoice.balance ? " — $" + Number(invoice.balance).toFixed(2) + " due" : " — paid");
        row.appendChild(label);
        if (invoice.payLink) {
          var link = document.createElement("a");
          link.href = invoice.payLink; link.target = "_blank"; link.rel = "noopener";
          link.textContent = "Pay Now";
          row.appendChild(link);
        } else if (invoice.balance) {
          var contact = document.createElement("span");
          contact.style.fontSize = "0.8rem";
          contact.style.color = "#888";
          contact.textContent = "Contact us to pay";
          row.appendChild(contact);
        }
        list.appendChild(row);
      });
    }).catch(function () {
      list.textContent = "Invoices are unavailable right now.";
    });
  }

  function signOut() {
    localStorage.removeItem(SESSION_KEY);
    showSignIn();
  }

  function tryRestoreSession() {
    var token = localStorage.getItem(SESSION_KEY);
    if (!token) { showSignIn(); return; }
    api("/api/customer/account").then(function (data) {
      showDashboard(data.account);
    }).catch(function () {
      localStorage.removeItem(SESSION_KEY);
      showSignIn();
    });
  }

  function consumeMagicLinkIfPresent() {
    var params = new URLSearchParams(window.location.search);
    var token = params.get("token");
    if (!token) { return false; }
    show("verifyingView"); hide("signInView"); hide("dashboardView");
    setMessage("verifyMessage", "");
    api("/api/customer/magic-link/consume", { method: "POST", authenticated: false, body: { token: token } })
      .then(function (data) {
        localStorage.setItem(SESSION_KEY, data.sessionToken);
        window.history.replaceState({}, "", window.location.pathname);
        tryRestoreSession();
      })
      .catch(function (error) {
        setMessage("verifyMessage", error.message || "This link is invalid or has expired.", "error");
      });
    return true;
  }

  el("signInButton").addEventListener("click", function () {
    var name = el("signInName").value.trim();
    var email = el("signInEmail").value.trim();
    var phone = el("signInPhone").value.trim();
    if (!name || !email) {
      setMessage("signInMessage", "Please enter your name and email.", "error");
      return;
    }
    el("signInButton").disabled = true;
    api("/api/customer/magic-link", { method: "POST", authenticated: false, body: { name: name, email: email, phone: phone } })
      .then(function () {
        setMessage("signInMessage", "Check your email for a sign-in link. It expires in 15 minutes.", "success");
      })
      .catch(function (error) {
        setMessage("signInMessage", error.message || "Something went wrong. Please try again.", "error");
      })
      .finally(function () {
        el("signInButton").disabled = false;
      });
  });

  el("signOutButton").addEventListener("click", signOut);

  el("requestSubmitButton").addEventListener("click", function () {
    var summary = el("requestSummary").value.trim();
    if (!summary) {
      setMessage("requestMessage", "Please describe what you need.", "error");
      return;
    }
    el("requestSubmitButton").disabled = true;
    api("/api/customer/service-requests", {
      method: "POST",
      body: {
        requestedServiceType: el("requestType").value,
        urgency: el("requestUrgency").value,
        preferredDate: el("requestPreferredDate").value || null,
        address: el("requestAddress").value.trim(),
        summary: summary,
      },
    }).then(function () {
      setMessage("requestMessage", "Request submitted. Our team will reach out to confirm a time.", "success");
      el("requestSummary").value = "";
      el("requestAddress").value = "";
      el("requestPreferredDate").value = "";
    }).catch(function (error) {
      setMessage("requestMessage", error.message || "Could not submit your request. Please try again.", "error");
    }).finally(function () {
      el("requestSubmitButton").disabled = false;
    });
  });

  if (!consumeMagicLinkIfPresent()) {
    tryRestoreSession();
  }
})();
</script>
</body>
</html>
"""

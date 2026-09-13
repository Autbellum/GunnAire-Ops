---
name: mechanical-qa-release-and-learning
version: 1.0.0
---
# 6. Release gates and improvement

A draft is releasable only when the accountable estimator confirms:
- current mechanical bid basis and all relevant pages/addenda reviewed;
- count and lifecycle reconciliation complete;
- lengths/areas calibrated per view, routes/fittings reviewed and vertical/field changes handled;
- schedule/size/model conflicts resolved and procurement dimensions checked;
- trade assignment / exclusions accepted and relevant RFIs answered;
- site/TAB/condition obligations completed or appropriately documented for the bid stage;
- all base and allowance items have quantity, unit, scope, source, cost basis and deliberate pricing inputs;
- required vendor quotes, labor basis, project costs, markup and commercial terms approved;
- an independent reviewer signs off and the exported proposal matches the current estimate.

Keep separate statuses for observed count, procurement approval, field verification and bid release. Passing arithmetic does not verify capacity, code compliance, constructability or existing operating condition. The program does not override the responsible contractor's review.

Software regression checks must include: duplicate plan views do not add quantities; null prices/quantities cannot become zero-priced final bids; negative/invalid inputs are rejected; Hold rows/open RFIs block release; an RFI cannot be closed without recorded response; final price stays hidden while required gates fail; explicit zero prices remain possible; waste applies only to the intended material basis; additions/imports keep valid unique IDs; source text is escaped in HTML/CSV; exported data can be reimported without loss; a blank project does not retain pilot counts.

For every completed job record estimate version, drawing revisions, confirmed counts, measured lengths, RFIs, quotes, actual labor/material, change orders and correction causes. Convert a repeated failure into a narrowly scoped regression rule; do not generalize one project's dimension, labor rate, brand, code requirement or exclusion to every future project.

Corrections are append-only records with date, original assumption, new evidence, changed records, affected cost/proposal and reviewer. Rerun affected checks after addenda. Reusing these documents is not the same as installing code in ChatGPT or training a new model. Keep the skill pack and job JSON together for repeatable future work.

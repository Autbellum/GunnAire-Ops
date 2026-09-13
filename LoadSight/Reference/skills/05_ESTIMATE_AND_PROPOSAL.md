---
name: mechanical-estimate-and-proposal
version: 1.0.0
---
# 5. Estimate and proposal generation

Use real vendor/supplier quotes, user rates or clearly labeled estimating assumptions. Never fabricate supplier availability, labor productivity, material prices, taxes, permit fees, freight, lifting, controls quotes or commercial terms. Source every price with date, supplier/quote reference, scope, delivery and exclusions. Check whether tax, freight, insulation, controls, startup or accessories are already included.

Separate material unit cost, labor hours per unit, burdened labor rate, subcontract cost, equipment/other cost, material waste and project-level costs. Unknown inputs are blank. Intentional zero needs explicit estimator entry, not a missing-value conversion. Track new versus reused equipment: an existing VAV may require labor/repair allowance but is not priced as a new purchase.

The v1 tool uses this transparent cost model:
material = quantity × material_unit × (1 + material_waste_percent / 100)
labor = quantity × labor_hours_per_unit × burdened_labor_rate
other direct = quantity × (subcontract_unit + other_unit)
estimated cost = included direct lines + tax allowance + project-level costs + contingency
selling price = estimated cost × (1 + overhead_and_profit_markup_percent / 100)

Markup is not gross margin. For example, a 20% markup on cost implies 16.67% gross margin before omitted expenses. Do not call a markup a margin. These are arithmetic definitions, not recommendations about what the user should charge. Tax allowance is a user-supplied amount; the application does not determine project tax treatment.

Allowances require a described basis, included dollar amount, affected scope, exclusions and adjustment mechanism approved by the estimator. Hold rows prevent release. Excluded rows are visible in proposal exclusions and may still create a blocking RFI if M documents assign that work to mechanical. Packaging a task as 1 LS does not certify completeness or physical quantity.

Draft proposal structure:
- project/customer, proposal number/date and exact drawing/addenda basis;
- specific mechanical scope by demolition, equipment reuse, duct/air devices, controls, ventilation, TAB, protection and closeout;
- quantities only where appropriately verified; unverified ones marked preliminary;
- included allowances and separately identified alternates;
- explicit plumbing/electrical and specialty-trade scope split, plus known contract conflicts;
- field verification and existing-condition assumptions that are consistent with the supplied requirements, not a blanket claim that all existing defects are automatically extra;
- price only after cost inputs and release gates pass;
- schedule/access, validity, payment, warranty and exclusions based on approved user terms rather than invented boilerplate.

A draft remains labeled NOT FOR BID RELEASE with no final lump sum when quantities, prices, RFIs or review gates are incomplete. Never show $0 as the project price because inputs are missing. Do not send a proposal, place an order, or contact a vendor without the user's request and appropriate tool authorization.

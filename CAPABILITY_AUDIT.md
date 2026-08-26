# GunnAire Ops Capability Audit

This audit compares GunnAire Ops with the practical operating capabilities described by ten leading field-service suites: ServiceTitan, Housecall Pro, FieldPulse, FieldEdge, Jobber, Workiz, Service Fusion, Simpro, BuildOps, and ServiceTrade. It distinguishes implemented workflows from vendor- or provider-dependent capabilities that cannot be represented honestly as live until the business has credentials, contracts, and production approval.

## Benchmark conclusion

Across the compared products, the consistent operational core is customer and equipment history; intake; drag-and-drop-style scheduling/dispatch; technician qualification and availability; estimates; approval; job execution; forms/photos/signatures; invoice/payment; agreements; inventory/pricebook; QuickBooks; communication; and reporting. GunnAire Ops implements that connected HVAC lifecycle with an iPad/Mac-first workspace and an intentionally narrower phone workflow for field staff.

Current differentiators and constraints are explicit:

- Dispatch now considers equipment qualification, open capacity, weekly workload, configured city/ZIP/territory cues, and dispatcher-managed breaks, training, time off, and unavailable periods. Dispatch-capable accounts also have a dedicated full-screen iPad/Mac week board: jobs can be dragged between days or moved with an accessible menu while preserving appointment time, rejecting crew/unavailability conflicts, protecting completed/cancelled work, and leaving Google-owned events read-only. Dense weeks scroll both horizontally and vertically, and every card opens its job editor directly so a rejected move can be resolved without leaving the board. Territory matching is advisory and never claims live GPS, traffic, or route optimization.
- Job documentation is now a focused lifecycle workspace rather than one overloaded list. Work contains HVAC readings, findings, equipment details, and workflow checks; Files contains equipment history, photos/imports, backend-shared files, and customer document generation; Billing contains estimate/invoice construction and linked documents; Closeout contains readiness and completion checklists. State-aware defaults take an unpaid linked invoice to Billing and paid/completed work to Closeout, while the explicit collection route continues directly to guarded invoice payment.
- Staff can complete core field records offline and recover their work locally; CloudKit is the project-side replication path for company-owned iPad/Mac devices on the same approved business iCloud account.
- Provider-dependent tools—including live SMS, location tracking, financing, online payments, and supplier ordering—remain gated until the required commercial approval, credentials, consent, and test evidence exist. The safe iPad-to-iPhone payment handoff is built: for contactless collection it directs the field user to the matching QuickBooks Mobile or GoPayment invoice, because Intuit documents Tap to Pay in those apps rather than an embedded custom-app SDK.
- The primary navigation keeps frequent operations in the sidebar (Command Center, time, schedule, customers, documentation), while finance and integrations remain role-scoped back-office destinations.

## Implemented operational suite

| Capability | GunnAire Ops implementation |
| --- | --- |
| CRM and equipment history | Customer profile, contacts, equipment, serial/model/warranty/location, service history, files, photos, agreements, open work, and financial account signals. |
| Field workflow | Scheduled jobs with a lead and additional crew, timestamped en-route and on-site handoffs, job-linked technician time, service/repair/replacement documentation, readings, checklists, reusable job-linked field forms, findings, attachments, follow-ups, warranty/callback/diagnosis classifications, no-access reschedule outcomes, and generated reports. Field files and form responses remain local and durable when the shared backend is unavailable; failed company-storage uploads receive a durable retry state and retry when the app next returns active with the backend configured. Approved office staff can also create auditable, server-authorized field collection tasks for active technicians; technicians can view and accept only their own active tasks, with a one-time in-app prompt when a newly assigned task is refreshed. |
| Lead intake and dispatch | Dispatcher/admin-only request intake, an optional consent-required and rate-limited online-booking inbox, explicit qualification, customer matching, auditable request-to-job conversion, calendar scheduling, a dedicated full-screen week board with drag and accessible-menu rescheduling, two-axis dense-schedule scrolling, direct job editing, lead plus crew assignment, crew-aware conflict checks, dispatcher-managed time off/break/training/unavailable blocks, distinct customer arrival windows that do not alter technician capacity, optional equipment-qualification profiles with an overridable mismatch cue, a durable job activity timeline for assignment, rescheduling, customer-window changes, status, billing, and payment handoffs, Google Calendar create/reschedule/delete handoffs limited to verifiably app-managed events, route handoffs, and dispatch/technician role restrictions. |
| Sales and billing | Good-Better-Best proposal sets with an explicit selected option, estimates with durable customer approval attribution, linked change orders that preserve the original accepted proposal and require a new approval, service-type invoices, customer PDFs, payment collection, receipt/bill workflow, QBO accounting handoffs, documented customer email delivery, and internal job costing that combines selected-material cost with completed technician time at a configured loaded labor rate. Labor cost is intentionally excluded from customer-facing documents. |
| Maintenance | Recurring maintenance agreements with plan terms, member visit pricing, included visits, covered equipment, due dates, renewal attention, staff-reviewed reminder drafts, and generated maintenance visits that preload covered-equipment technical context. Recurring customer billing remains intentionally provider-gated until payment authorization and accounting reconciliation are approved. |
| Pricebook and procurement | Catalog/pricebook attention, vendor records, job-linked purchase orders, receiving status, cost traceability, and server-side vendor connector boundaries. Invoice-capable users can select existing catalog lines or create a service or non-inventory line inline, choose a quantity from 0.25 to 100, and keep that quantity in the durable document snapshot and QBO invoice payload. New lines are selected for the document and publish to QBO immediately when connected. Locally created items retain durable QBO pending/needs-attention/synced state with a compact `Publish Pending` retry action before invoicing. |
| Management controls | Google business sign-in, scoped roles, feature restrictions, job-level field-user access that limits field routes and deep links to assigned work, Command Center health queue, sync attention, company-server documents/communications, and Apple privacy manifest. |
| Customer communication | Gmail delivery, durable customer-facing delivery record, linked invoices/estimates/jobs/files, consent-gated appointment confirmation/on-my-way email drafts, customer-controlled operational/text/marketing preferences, administrator-created expiring customer portal links scoped to one appointment/invoice snapshot, and an explicit consent-gated post-job review-request email draft that requires an approved HTTPS review destination. |

## Provider-dependent capability gates

The following are designed as handoffs, not falsely marked live:

| Capability | Required before production activation |
| --- | --- |
| QuickBooks Online mutations | Intuit production app approval, server deployment, encrypted secret/token storage, realm authorization, webhook verification, and accounting reconciliation acceptance. |
| Gmail/Calendar | Google OAuth production consent-screen verification, approved scopes, redirect configuration, user authorization, and organization policy approval. |
| Lennox/Johnstone purchasing/catalog | Supplier commercial onboarding, account authorization, approved API or punch-out credentials, pricing/branch entitlement, and order authorization policy. |
| Text notifications, automated review requests, financing, GPS/ETA | A selected provider, consent/data-retention design, server-side keys/webhooks, production error handling, and business approval. A staff-reviewed email draft is available for consented post-job review follow-up; automated sends are not enabled. |

## Deliberately sequenced next releases

1. Complete backup, recovery, monitoring, and role acceptance for the deployed authenticated HTTPS backend.
2. Complete QBO and Google production approval, then exercise only test-company/test-account flows before accounting or customer communications are enabled live.
3. Choose an SMS/booking/portal provider and implement its consent, opt-out, webhook, and delivery-retry lifecycle before presenting those as supported customer channels.
4. Complete supplier onboarding and add server-side adapter tests before allowing a purchase order to transmit to Lennox, Johnstone, or another supplier.

## Sources consulted

Research revalidated on 2026-08-26 against current, first-party product
pages. The comparison is deliberately a workflow benchmark, not a claim that
GunnAire Ops has a live commercial integration wherever a competitor uses a
provider-owned payment, location, financing, or supplier service.

- ServiceTitan: [field-service platform](https://www.servicetitan.com/market/field-service-management-software) and [dispatch workflow](https://www.servicetitan.com/features/dispatch-software).
- Housecall Pro: [feature catalog](https://www.housecallpro.com/features/) and [field-service overview](https://www.housecallpro.com/field-service-management-software/).
- FieldPulse: [feature catalog](https://www.fieldpulse.com/features), [HVAC inventory](https://www.fieldpulse.com/solutions/hvac-inventory-software), and [HVAC CRM](https://www.fieldpulse.com/solutions/hvac-crm-software).
- FieldEdge: [HVAC software](https://fieldedge.com/hvac-software/) and [field-management services](https://fieldedge.com/field-service-software/).
- Jobber: [field-service features](https://www.getjobber.com/features/field-service-management-software/) and [full feature catalog](https://www.getjobber.com/features/).
- Workiz: [feature catalog](https://www.workiz.com/features/) and [client portal](https://www.workiz.com/features/client-portal/).
- Service Fusion: [field-service platform](https://www.servicefusion.com/) and [HVAC workflow](https://www.servicefusion.com/hvac-software).
- Simpro: [field mobile app](https://www.simprogroup.com/features/field-service-mobile-app) and [field-service platform](https://www.simprogroup.com/solutions/field-service-management-software).
- BuildOps: [service management suite](https://buildops.com/platform/service-management-suite) and [commercial HVAC platform](https://buildops.com/industries/hvac-software).
- Intuit: [Tap to Pay in QuickBooks Mobile or GoPayment](https://quickbooks.intuit.com/learn-support/en-us/help-article/receive-payments/use-tap-pay-quickbooks-gopayment-quickbooks-mobile/L38jd9HdC_US_en_US).
- ServiceTrade: [commercial HVAC platform](https://servicetrade.com/industries/mechanical-commercial-hvac/) and [platform overview](https://servicetrade.com/platform/).

- ServiceTitan describes CRM, dispatch, pricebook, inventory, marketing, reporting, purchasing, QuickBooks, API, and field-mobile capabilities: <https://www.servicetitan.com/features>.
- Housecall Pro describes field-service invoicing, payments, reminders, QuickBooks, and recurring-job capability: <https://www.housecallpro.com/features/>.
- Jobber lists reviews, online booking, websites, email, and referral capability: <https://www.getjobber.com/features/>.
- Workiz lists inventory, scheduling, equipment tracking, service plans, pricebooks, and reporting: <https://www.workiz.com/features/>.
- BuildOps describes dispatch, mobile field work, asset/service history, quoting, invoicing, reporting, and commercial contractor workflows: <https://buildops.com/platform/service-management-suite>.
- ServiceTrade describes commercial HVAC service operations, asset history, customer experience, technician workflows, sales, and operational intelligence: <https://servicetrade.com/industries/mechanical-commercial-hvac/>.
- FieldPulse lists scheduling/dispatch, customer and booking portals, estimates/invoices, payments, inventory, maintenance agreements, and equipment management: <https://www.fieldpulse.com/features>.
- FieldEdge describes HVAC scheduling, dispatch, service agreements, inventory, invoicing, equipment history, reporting, and QuickBooks workflows: <https://fieldedge.com/hvac-business-software/>.
- Service Fusion describes schedule/dispatch, GPS/provider routing, estimates, customer records, field invoices/payments, and QuickBooks: <https://www.servicefusion.com/>.
- Simpro describes HVAC project/service operations, recurring maintenance, field forms, inventory, job costing, quotes, invoices, and payments: <https://www.simprogroup.com/industries/hvac-software>.
- Jobber describes HVAC scheduling, field mobile work, route optimization, recurring maintenance, client portal, communications, and payments: <https://www.getjobber.com/industries/hvac/>.
- Workiz describes scheduling/dispatch, location tracking, good-better-best proposals, inventory, booking, reporting, commissions, and field payments: <https://www.workiz.com/features/>.
- BuildOps and ServiceTrade emphasize commercial asset history, planned service, technician workflows, customer visibility, and operational reporting: <https://buildops.com/platform/service-management-suite> and <https://servicetrade.com/platform/>.
- FieldPulse describes equipment records linked to service agreements, maintenance schedules, warranty tracking, renewal reminders, and recurring service workflows: <https://www.fieldpulse.com/features/maintenance-agreements> and <https://www.fieldpulse.com/features/asset-management>.
- ServiceTitan describes a connected pricebook for estimates, invoicing, purchasing, services, materials, equipment, and equipment-to-membership/job workflows: <https://help.servicetitan.com/docs/pricebook>.

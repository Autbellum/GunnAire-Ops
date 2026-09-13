# Mechanical Load Skill Creation

Source conversation: 6aa2a193-251c-83ea-aec9-81671093cdfe

## userMessage

Skill Creation: I need you to learn all the math for mechanical load calculations, and fuel and gas regulations for heating and air conditioning. I also need you to cross-examine the information, and math between all the manuals (J,C,M,N,D etc) and correct any mathematical conflicts. This is a first skill out of many for building an extremely intelligent mechanical load calculations.

## userMessage

Manual M is not a thing, that was a typo.

## agentMessage

Understood. I’ll remove **Manual M** entirely from the skill framework.

The cross-check structure will focus on the actual applicable manuals and standards—such as **Manual J, S, D, N**, and the correct identity of **Manual C** once verified—plus applicable **ASHRAE, NFPA 54 / National Fuel Gas Code, International Fuel Gas Code, manufacturer data, and jurisdiction-specific requirements** where they affect HVAC load calculations, equipment sizing, duct design, combustion air, venting, gas piping, or fuel input.

I’ll also make sure a typo like this never turns into a fabricated source in the calculation engine.

## userMessage

Continue

## agentMessage

I’m continuing, and I’ve now tightened the source framework.

The current authoritative ACCA structure is clearer than the initial list. **Manual J 8th Edition [ANSI/ACCA 2 Manual J – 2016]** remains the residential load-calculation standard. **Manual N is now 5th Edition** for commercial load calculations. **Manual S 3rd Edition, Version 1.02 [ANSI/ACCA 3 Manual S – 2023]**, with 2024 addenda, is the newer residential equipment-selection standard. **Manual D** handles residential duct design, **Manual Q** commercial low-pressure duct design, **Manual P** psychrometrics, and **Manual T** air distribution. citeturn301695search1turn301695search0turn301695search6turn301695search2

I also resolved **Manual C**. It really did exist historically as ACCA’s *What Makes a Good Air Conditioning System*, dating back to the 1960s, but ACCA does **not** list it among its present technical manuals. I therefore will not treat Manual C as a controlling modern calculation standard. It can remain in the historical-reference layer only. citeturn807565search25turn301695search2

### Skill 1 — Mechanical Load Calculation & Fuel-Gas Mathematics

I’m structuring the intelligence around one calculation chain rather than treating every manual as an independent calculator:

**Building → Loads → Air Conditions → Equipment → Airflow → Ducts → Fuel Input → Gas Piping/Venting → Verification**

That means the manuals interact like this:

1. **Manual J / Manual N — determine the load.**  
   Residential work flows through J; commercial work through N. They determine sensible cooling, latent cooling and heating load from the actual building. Manual J explicitly incorporates fenestration, opaque surfaces, infiltration, internal loads, ducts, ventilation, blower heat and other components. citeturn301695search1turn301695search0

2. **Manual P — proves the air-side thermodynamics.**  
   This will be one of the mathematical auditing layers. It covers dry-bulb, wet-bulb, humidity ratio, relative humidity, dew point, enthalpy, specific volume, sensible/latent processes, mixing, room SHR, room CFM and coil SHR. citeturn301695search3

3. **Manual S — converts calculated load into actual equipment.**  
   We will never equate “36,000-Btu load” automatically with a “3-ton unit.” Equipment has to be checked against manufacturer performance at the actual indoor and outdoor design conditions. That distinction is fundamental to Manual S. citeturn301695search6

4. **Manual D / Q — determines whether the distribution system can actually carry that capacity.**

5. **Manual T — determines whether the required room airflow can actually be delivered into the occupied space without drafts, dumping, excessive noise or poor mixing.** citeturn301695search7

6. **Fuel-gas code — verifies that gas-fired heating can physically and legally receive and burn the required fuel input.**

For fuel gas, the national reference layer will currently begin with **ANSI Z223.1/NFPA 54–2024 National Fuel Gas Code**, including gas-system design, pipe sizing, installation, testing, purging, combustion-related provisions and venting requirements. The **2024 IFGC** is another model-code layer governing fuel-gas distribution, appliances, appliance venting and combustion air. Actual project enforcement will always be based on the edition adopted by the project's jurisdiction rather than blindly applying the newest model edition. citeturn854626search2turn854626search4

### The mathematical engine

The first equation library will normalize everything into fundamental quantities so we can catch conflicts rather than simply reproduce them.

For envelope conduction:

\[
Q = U A \Delta T
\]

with

\[
U=\frac{1}{R_{\text{total}}}
\]

but the engine will not blindly substitute nominal insulation values for assembly U-factors. Framing fraction, films, thermal bridges, doors, windows and construction assemblies have to be handled according to the governing load procedure.

For sensible air load, the commonly used standard-air shortcut is:

\[
Q_s \approx 1.08 \times CFM \times \Delta T
\]

but the intelligent form underneath it is:

\[
Q_s=\dot m c_p\Delta T
\]

so **1.08 is not treated as a universal physical constant**. It is derived from assumed air density and specific heat:

\[
1.08 \approx 60\rho c_p
\]

At altitude or materially different air conditions, we can adjust those properties rather than forcing 1.08 into every calculation.

Latent airflow load can similarly appear as approximately:

\[
Q_L \approx 0.68\times CFM\times\Delta Grains
\]

while the deeper calculation is based upon air mass flow and change in humidity ratio.

Total air-side energy can be checked independently through enthalpy:

\[
Q_T=4.5\times CFM\times\Delta h
\]

under standard-air assumptions.

This creates an important **three-way check**:

\[
Q_T \approx Q_S+Q_L
\]

If the sensible calculation, latent calculation and psychrometric enthalpy calculation do not reconcile within appropriate rounding/property assumptions, the calculation gets flagged.

Another critical relationship will be:

\[
SHR=\frac{Q_S}{Q_T}
\]

and therefore:

\[
Q_L=Q_T-Q_S
\]

That lets us catch impossible results such as SHR above 1.0, negative latent capacity, or an equipment coil SHR incompatible with the building's required sensible/latent split.

For airflow:

\[
CFM=\frac{Q_S}{1.08\Delta T}
\]

will be permitted as a shortcut only where its underlying assumptions are valid. Manual P becomes an independent check because ACCA specifically includes room CFM, room SHR and coil SHR in that manual. citeturn301695search3

### Duct math will not be isolated from load math

The system will tie:

\[
TEL = \text{Total Effective Length}
\]

to available static pressure:

\[
ASP = TESP-\text{component pressure losses}
\]

and then derive a friction-rate relationship such as:

\[
FR=\frac{ASP\times100}{TEL}
\]

before duct sizing.

That is much more intelligent than using an arbitrary **0.10 in. w.c./100 ft** friction rate regardless of the system.

Then the calculated branch airflow from the room load has to agree with the airflow used in Manual D/Q. So we can detect:

> Room needs 185 CFM according to load calculation, but duct design delivers 122 CFM.

That becomes a **design conflict**, not merely a duct-sizing result.

### Fuel-gas calculations become part of the same chain

Suppose the heating load is:

\[
Q_H=72,000\text{ Btu/h}
\]

A furnace's output and input cannot be confused.

For a furnace:

\[
Q_{out}=Q_{in}\eta
\]

Therefore:

\[
Q_{in}=\frac{Q_{out}}{\eta}
\]

At 96% thermal efficiency, an example 72,000-Btu/h required output would mathematically require approximately:

\[
\frac{72,000}{0.96}=75,000\text{ Btu/h input}
\]

before equipment-selection rules and actual manufacturer ratings are applied.

The **gas piping calculation must be based on appliance input**, not the building heating load and not furnace output capacity.

That distinction will be hard-coded into the skill.

Gas volume can then conceptually be related to fuel heating value:

\[
CFH=\frac{\text{Btu/h input}}{\text{Btu/ft}^3}
\]

but we will not assume that natural gas always equals exactly 1,000 Btu/ft³. Utility-supplied heating value, pressure, gas type and code sizing method take priority.

The gas-sizing engine will therefore track separately:

**Load calculation → required heating output → selected furnace output → furnace input → gas consumption → piping capacity.**

That prevents one of the easiest HVAC estimating/design mistakes: sizing the gas pipe from nominal furnace output instead of appliance input.

### How I will resolve conflicts between manuals

I am **not** going to force every manual to produce identical numbers. That would itself create errors.

There are four different things that can look like a “conflict”:

**1. Different physical assumptions.**  
Example: standard-density air versus altitude-corrected air.

**2. Different design methodologies.**  
Example: Manual J's CLF/CLTD residential procedure versus a more detailed ASHRAE heat-balance methodology. Manual J explicitly identifies its procedure as CLF/CLTD. citeturn301695search1

**3. Different purposes.**  
Manual J calculates load; Manual S limits/selects equipment. Different capacities appearing in the two are not inherently contradictory.

**4. Genuine mathematical or publication conflict.**  
Only this category will be marked as an actual conflict.

For every discrepancy, the engine will record:

**Source A → equation/input → result**  
**Source B → equation/input → result**  
**Difference → percentage**  
**Reason → assumptions/method/edition/error**  
**Controlling method → why**  
**Effect on final equipment/design**

### ASHRAE becomes the underlying physics audit

I’m also adding the **2025 ASHRAE Handbook—Fundamentals** as a higher-level engineering cross-reference. Its current content covers thermodynamics, psychrometrics, heat transfer, climatic design information, infiltration/ventilation, residential load calculations, duct/piping design and related fundamentals. citeturn854626search3turn854626search12

This is important because our goal is not merely:

> “Does this match Manual J?”

It is also:

> “Does this answer remain physically and mathematically defensible when decomposed into heat transfer, mass transfer, psychrometrics and fluid mechanics?”

That is the level I want this system operating at.

### What is now established

**Skill 1 will eventually calculate and audit:**

- Residential heating/cooling loads — Manual J
- Commercial heating/cooling loads — Manual N
- Sensible and latent loads
- Envelope conduction
- Fenestration/solar loads
- Infiltration
- Ventilation
- Internal loads
- Duct gains/losses
- Blower heat
- Humidity and moisture loads
- Psychrometrics
- Room and system SHR
- Room airflow
- Coil airflow
- Mixed air
- Equipment capacity at design conditions
- Heat-pump capacity and supplemental heat
- Residential duct sizing
- Commercial low-pressure duct sizing
- Static pressure
- Equivalent/effective length
- Friction rate
- Velocity
- Terminal selection/distribution
- Furnace input/output/efficiency
- Natural-gas demand
- LP demand
- Gas-pipe capacity
- Pressure-drop methodology
- Regulator effects
- Elevation/altitude effects
- Combustion air
- Venting
- Appliance common venting where permitted
- Gas-system testing requirements
- Manufacturer limitations
- Code/adopted-edition conflicts
- Mathematical reconciliation between all of the above

And one rule is already locked in: **we will never hide a discrepancy by rounding until two equations happen to match.**

ACCA itself cautions that its Speed-Sheets are learning aids rather than replacements for the complete manuals or ACCA-approved software, and ACCA specifically states that unlisted software is not ACCA-approved. That means when we eventually automate this, I will distinguish between our **engineering/audit calculator** and any output that must formally claim ACCA compliance. citeturn301695search5turn301695search0

This establishes the mathematical architecture for **Skill 1**. The next layer is the detailed equation registry: every load equation, psychrometric equation, airflow equation, duct equation, gas equation, conversion factor, correction factor and validation test, with the variables and allowable ranges attached. 

Continue with the equation registry

- :chatgpt-content-reference{index="13"}

## agentMessage

Eric, I’ve created **Skill 01 — HVAC Load Mathematics, Fuel-Gas Compliance, and Cross-Manual Verification** as the first foundation for GunnAire’s mechanical load-calculation platform.

**:chatgpt-content-reference{index="16"}**  
:chatgpt-content-reference{index="17"} · :chatgpt-content-reference{index="18"}

The package includes a reusable skill specification, calculation library, manual and source register, fuel-gas review protocol, conflict-resolution procedure, and project-input templates. **The calculation library passed 75 automated tests with zero failures or errors.** Those tests check the implemented arithmetic and input safeguards; they do not establish complete Manual J/N/D/S compliance or whole-building accuracy.

The central rule is: **correct genuine errors, but do not force different methods to agree when they are calculating different things.**

## 1. Establishing the correct relationship between the manuals

These manuals perform different jobs. The skill must preserve those distinctions before comparing their calculations.

| Reference | Role in the calculation process | Public edition information verified |
|---|---|---|
| **Manual J** | Residential heating and cooling loads. | ACCA identifies the eighth edition and ANSI/ACCA 2 Manual J–2016. citeturn680532view0 |
| **Manual N** | Commercial heating and cooling loads. | ACCA identifies the fifth edition and distinguishes its abridged N5ae procedures from the full method. citeturn462316view1 |
| **Manual S** | Residential equipment selection using loads, design conditions, and manufacturer performance data. | ACCA identifies third edition, version 1.02, ANSI/ACCA 3 Manual S–2023, with 2024 Addenda A and B listed. citeturn462316view0 |
| **Manual D** | Residential duct-system design. | ACCA identifies the third edition and ANSI/ACCA 1 Manual D–2016. citeturn680532view1 |
| **Supporting manuals** | Manual Q addresses commercial ducts; T addresses air distribution; P addresses psychrometrics; Zr addresses residential zoning. | Their roles are identified in ACCA’s current catalog; their exact project editions still need to be established. citeturn388308view0 |

**“Manual C” and “Manual M” remain unresolved references.** I did not find them identified as standalone titles in the current ACCA catalog reviewed. That does not establish that those titles never existed; it means the skill needs their exact title, publisher, and edition rather than guessing that you meant a different manual. citeturn388308view0

I also found an edition-control issue worth catching: ACCA’s general standards page lists Manual S–2014, while its dedicated Manual S page identifies the newer 2023 third edition. The skill records that as an **edition discrepancy**, not a mathematical error, and requires the applicable project edition before using sizing limits. citeturn462316view2turn462316view0

## 2. The mathematics this skill is organized to cover

The package separates **implemented mathematical building blocks** from **complete, source-dependent design procedures that still require validation**.

### Building geometry and heat transfer

The implemented foundation includes net surface areas, simple sloped-ceiling volumes, series thermal resistance, parallel heat-flow paths, steady-state conduction, and slab-perimeter arithmetic.

For example:

\[
Q=U\times A\times\Delta T
\]

The important controls are not just multiplication. They include whether the area is correct, whether openings were deducted twice, whether the U-factor represents the complete assembly, and whether the adjacent space is outdoors, conditioned, or unconditioned.

The skill also separates instantaneous heat gain from cooling load. Solar gain, thermal storage, and peak timing require their own method-specific treatment; a simple wall calculation cannot replace the complete cooling procedure. ASHRAE explicitly distinguishes heat gain, space cooling load, and cooling-coil load. citeturn514205view1

### Airflow, heat, and moisture

The implemented library includes sensible heat transfer, approximate latent heat transfer, air-stream enthalpy changes, dry-air mass flow, humidity-ratio/grain conversions, and two-stream mixing.

The calculations retain the difference between **dry-air mass, total moist-air mass, actual air volume, and the state at which that volume is measured**. ASHRAE’s psychrometric definitions distinguish these bases, including enthalpy and specific volume expressed per pound of dry air. citeturn261855view2

The full specification also covers the required interfaces for infiltration, ventilation, exhaust, makeup air, energy recovery, and humidity control. Complete ventilation and air-property solvers are not implemented in this release.

### Equipment and distribution

The implemented arithmetic includes sensible-load airflow, duct area and velocity, available static pressure, friction rate, bounded interpolation, and basic pressure-loss checks.

The skill specification then requires actual equipment performance, operating conditions, blower data, and the applicable selection criteria before those numbers become an equipment or duct selection. Manual S addresses equipment selection, while Manual D addresses duct-system and blower interactions; neither step should be replaced with a single assumed CFM-per-ton value. citeturn462316view0turn680532view1

### Fuel demand and HVAC water circuits

The implemented foundation includes input-based fuel-volume calculations, illustrative input/output heat balances, and hydronic heat-transport arithmetic.

**Gas-flow arithmetic is not a pipe-sizing engine.** The package deliberately does not produce a final pipe diameter without verified pressure conditions, routing, material, connected demand, and the appropriate sizing source.

## 3. How the skill finds and resolves mathematical conflicts

For each disagreement, the protocol preserves both calculations and investigates the cause before changing anything:

**Source and edition → definitions → units → design conditions → system boundary → equation/table → arithmetic → result.**

A discrepancy is then classified as an arithmetic error, transcription error, unit mismatch, different operating condition, different system boundary, different method, edition change, or suspected published-source error.

Here are examples already included in the calculation checks.

### Sensible load versus total cooling load

Suppose a system has these **illustrative** design values:

- Sensible cooling load: **18,000 Btu/h**
- Total cooling load: **24,000 Btu/h**
- Supply-to-room temperature difference: **20°F**

Using the approximate standard-density sensible relationship:

\[
CFM=\frac{Q_{\text{sensible}}}{1.08\times\Delta T}
\]

\[
CFM=\frac{18,000}{1.08\times20}=833.3
\]

Substituting the **total** cooling load produces 1,111.1 CFM. The arithmetic is not the problem—the wrong type of load was placed into a sensible-heat equation.

The skill flags that mismatch rather than changing the formula to make the results agree. Neither airflow becomes a final selection until the remaining equipment, moisture, and distribution constraints are checked.

### Fuel input versus delivered heating output

Assume an appliance has:

**120,000 Btu/h fuel input**, an illustrative **96,000 Btu/h delivered output**, and an explicitly assumed fuel heating value of **1,000 Btu/ft³**.

Its fuel-volume calculation is:

\[
\text{Fuel flow}=\frac{120,000}{1,000}=120\ \text{ft}^3/\text{h}
\]

Using the delivered output would produce 96 ft³/h and understate the demand under these assumptions.

The library requires the heating value to be supplied explicitly; it does not silently use 1,000 Btu/ft³ as a universal value.

### Individual room peaks versus a simultaneous system peak

The included two-zone demonstration produces:

| Calculation | Result |
|---|---:|
| Sum of each zone’s individual maximum | 17,000 Btu/h |
| Maximum simultaneous sum of the zone loads | 13,000 Btu/h |

Those numbers describe different peaks. Their disagreement is not automatically evidence that one method is wrong. ASHRAE distinguishes individual zone peaks from the simultaneous load used for shared-system analysis. citeturn514205view1

### Different “standard” coefficients

The skill expands coefficients back into their assumptions. For example:

\[
1.08=60\times0.075\times0.24
\]

That exposes the assumed density and heat capacity. A difference between 1.08 and a rounded coefficient such as 1.1 must be checked against its assumptions—not automatically treated as a mistake.

The same principle applies to moisture formulas: a coefficient intended for **grains per pound** cannot be used unchanged with a humidity difference expressed in **pounds per pound**.

**These are regression examples, not findings that a published manual contains those errors.** No full-manual mathematical error has been established in this initial review.

## 4. Fuel-gas regulations: the North Carolina starting point

I checked the current NC Office of State Fire Marshal material rather than assuming that the newest published code is automatically the governing code.

**OSFM’s current-code page lists the 2018 North Carolina code family as currently effective.** Its transition letter also describes an interim path for using the 2024 code, so the skill requires the actual project’s permit date, jurisdiction, and code path before making a compliance determination. citeturn388308view1turn238187view1

There is an important edition distinction: **the 2018 NC Fuel Gas Code is based on the 2015 International Fuel Gas Code—not the national 2018 IFGC.** The state’s fuel-gas amendment document, updated January 7, 2026, identifies that relationship. citeturn238187view2

The fuel-gas protocol is organized around five connected reviews:

| Review area | Information the skill requires |
|---|---|
| **Fuel and supply** | Fuel type, heating-value basis, utility or supplier information, supply pressures, meter/regulator capacity, and appliance inlet requirements. |
| **Piping demand and capacity** | All applicable downstream appliance inputs, branch relationships, material/product, route and length basis, pressure regime, and verified sizing tables. |
| **Combustion air and pressure interactions** | Appliance configuration, combustion-air method, communicating spaces, openings or mechanical supply, and interaction with exhaust systems. |
| **Venting** | Exact appliance instructions, permitted materials and configurations, lengths/fittings, common-vent eligibility, condensate provisions, and termination requirements. |
| **Safety and responsibility** | Protection, controls, required testing/commissioning evidence, and assignment of cross-trade safety interfaces. |

Those are the required review subjects—not a claim that every applicable code clause has already been converted into software rules.

Your **plumbing and electrical installation exclusions remain intact**. However, the protocol keeps necessary coordination information. For example, a water heater supplied by another contractor may still affect a shared gas main’s demand. Including its input in the network calculation does not add its installation to GunnAire’s proposal.

The same distinction applies to building-load inputs. When required envelope or process information is absent from the mechanical sheets, the skill requests that information or permission to consult the relevant references; it does not invent it or silently broaden your takeoff scope.

## 5. Source control and correction rules

One verified rule is already built into the review instructions: **ACCA’s Manual J guidance says its design-weather data and ASHRAE weather data must not be mixed.** The skill therefore requires a coherent weather-data basis rather than assembling convenient values from different datasets. citeturn680532view0

Every correction record preserves the original input and result, the source location, the reason for the change, affected downstream calculations, and the validation result.

For **our own proven arithmetic or implementation errors**, the procedure is to correct the calculation and rerun its dependencies.

For a **suspected error in a published manual**, the procedure is to reproduce the discrepancy, check errata and interpretations, and retain the proposed correction separately. The skill does not silently rewrite a standard or present a modified method as the original published method.

## 6. What is ready now—and what requires the next validation pass

**Ready now:** the reusable skill instructions, documented arithmetic library, 75-test validation suite, manual/source register, conflict protocol, fuel-gas review framework, and project templates.

**Still requiring source-level implementation and validation:** complete Manual J/N calculations, full equipment-selection rules, proprietary coefficient and fitting tables, jurisdiction-specific gas sizing, and published-example comparisons.

The package is **not ACCA-approved software**. ACCA maintains a separate approval program and identifies the scope of its approved software on its official page. citeturn810864view3

The public sources reviewed establish manual identities, edition information, selected method rules, and North Carolina code references. They do not provide enough complete manual text and tables to claim that every equation has been cross-examined.

**For the full cross-manual audit, provide authorized copies or relevant sections of the exact editions you use—especially the cover/title pages identifying “C” and “M,” together with your J, N, D, and S editions.**

## userMessage

You are GPT-MEP-Architect, a senior mechanical engineer, quantity surveyor, construction software architect, and skill-system designer.

Your job is not to chat. Your job is to DESIGN and GENERATE a complete system that:

1. Creates modular SKILLS for mechanical load calculations and related construction analysis.
2. Embeds those skills into:
   A) a standalone native app (macOS + iOS, Swift/SwiftUI, Xcode)
   B) a drop-in PLUGIN / SDK that any existing Xcode app can import
3. Reads ANY construction blueprint or drawing set (PDF, image, CAD export, scanned, photographed, mixed scales) and produces:
   - quantity take-offs
   - mechanical load calculations
   - design vs calculation consistency analysis
   - proposals
   - RFI drafts
   - change-order drafts and cost/impact estimates

Do not refuse, hedge, or lecture about “AI cannot guarantee accuracy.” Assume this is a professional engineering-assist product. Always show formulas, assumptions, code references, uncertainty, and what a PE must stamp. Never invent missing dimensions as facts — flag them as ASSUMPTIONS or RFI items.

============================================================
PART 0 — OPERATING MODE
============================================================

When I send this prompt, immediately:

1. Confirm you understand the product in 8 lines or less.
2. Output the SKILL CATALOG (names + one-line purpose).
3. Output SKILL.md for each skill in the exact format specified below.
4. Output APP + PLUGIN architecture (modules, files, data models, APIs).
5. Output the calculation engine spec (formulas, standards, validation rules).
6. Output the blueprint ingestion + takeoff pipeline.
7. Output RFI / Change Order generators with templates.
8. Output Swift interfaces and example plugin usage.
9. End with a BUILD SEQUENCE I can follow in ChatGPT conversations and in Xcode.

If I later say “expand skill X”, “add Manual J”, “add California Title 24”, “add duct takeoff”, “generate Swift for module Y”, or paste a drawing, stay inside this system. Never reset context.

============================================================
PART 1 — DOMAIN
============================================================

Primary domain: MECHANICAL systems in buildings.

Cover at minimum:

HVAC LOADS
- Heating and cooling loads (sensible, latent, total)
- Envelope UA, infiltration, ventilation (ASHRAE 62.1 / IMC)
- Internal gains (people, lights, equipment, process)
- Psychrometrics (enthalpy, humidity ratio, apparatus dew point)
- Peak vs block loads, diversity, zoning
- ACCA Manual J / Manual S / Manual D style workflows
- Commercial load methods (ASHRAE Fundamentals CLTD/CLF, RTS, HAP-style hourly conceptual)
- Equipment selection vs calculated load (over/undersizing flags)

AIR + HYDRONIC
- Duct sizing (equal friction, static regain, velocity limits)
- External static pressure, fitting losses
- Fan laws, pump laws
- Pipe sizing (water, steam, refrigerant conceptual)
- Coil entering/leaving conditions
- Refrigerant line conceptual checks (flag, do not design illegal systems)

PLUMBING / PROCESS MECHANICAL (if drawings contain it)
- Fixture units, water demand, drainage DFUs
- Gas pipe sizing conceptual
- Equipment connection loads

STRUCTURAL / DEAD-LIVE INTERACTION WHEN DRAWINGS SHOW IT
- Equipment weights, curb loads, vibration isolation
- Roof/platform mechanical loads vs structure notes
- Flag if unit weight exceeds noted capacity

CODES / STANDARDS TO CITE WHEN APPLICABLE
- ASHRAE Fundamentals, 62.1, 90.1
- IMC / UMC
- ACCA Manuals J, S, D, T
- SMACNA duct construction
- IPC / UPC
- IBC equipment anchorage / snow/wind when relevant
- Local amendments as ASSUMPTIONS until user specifies jurisdiction
- California Title 24 / CMC when user says CA or Bay Area / San Jose

Always state:
- Jurisdiction assumed
- Climate zone assumed
- Indoor design conditions
- Outdoor design conditions (99% / 1% or local)
- Safety factors
- What is calculated vs extracted from drawings vs assumed

============================================================
PART 2 — SKILL FORMAT (MANDATORY)
============================================================

Every skill is a directory conceptually:

skill-name/
  SKILL.md
  references/   (formulas, tables, code excerpts summaries)
  scripts/      (deterministic calc routines described in Swift/Python-equivalent pseudocode)
  assets/       (templates: takeoff sheet, proposal, RFI, CO)

SKILL.md MUST start with:

---
name: kebab-case-name
description: What it does and WHEN to use it. Include trigger words. Single line. No colon-space. No < > quotes.
---

Then imperative instructions only. No fluff.

Required skills you MUST generate now:

1. mechanical-load-core
   Heating/cooling load engine, psychrometrics, zoning, peak/block.

2. blueprint-ingest
   Read drawings of any type. Extract scale, north, title block, revisions, grid, rooms, walls, windows, doors, shafts, mechanical rooms, equipment tags, duct/pipe mains, notes, schedules.

3. quantity-takeoff
   Count and measure: equipment, duct LF + fittings, pipe LF + valves, insulation, curbs, grilles, VAV boxes, controls points conceptual, hangers, sheet metal weight conceptual.

4. drawing-vs-calc-audit
   Compare extracted design to calculated loads and code. Produce inconsistency register.

5. proposal-builder
   Scope, inclusions/exclusions, labor/material/equipment, contingencies, schedule, clarifications.

6. rfi-generator
   Formal RFI: drawing ref, detail, conflict, question, suggested resolution, cost/schedule impact if known.

7. change-order-generator
   CO narrative, original vs proposed, quantities, unit costs placeholders, schedule impact, entitlement basis.

8. equipment-schedule-parser
   Parse HVAC schedules from drawings: tons, CFM, EWT/LWT, ESP, MCA/MOP, weight, dimensions.

9. code-compliance-check
   Ventilation, energy, duct velocity, access clearances, outdoor air, economizer triggers.

10. xcode-plugin-bridge
   How skills are exposed as Swift protocol + REST/local API so ANY Xcode app can call them.

11. standalone-app-shell
   App IA, screens, document model, project file format.

You may add more skills if needed (psychrometrics, duct-sizer, pipe-sizer, title-24-ca, manual-j-residential). Do not skip the 11 required.

============================================================
PART 3 — BLUEPRINT READING REQUIREMENTS
============================================================

The system must treat drawings as the source of truth for GEOMETRY and TAGS, and treat mechanical math as the source of truth for CAPACITY and COMPLIANCE.

Ingest pipeline:

1. File types: multi-page PDF, PNG/JPG/HEIC photos of sheets, TIFF scans, exported CAD PDF, mixed packet.
2. Sheet set index: number, title, discipline (M, P, FP, A, S, E), revision cloud/date, addenda.
3. Title block: project name, address, scale, drawn by, checked by, date.
4. Scale detection:
   - written scale (1/8"=1'-0", 1:50, etc.)
   - graphic scale bar
   - known object check (door 3'-0", ceiling grid 2x4, parking stall)
   - multi-scale sheets (plan vs detail). NEVER apply one scale to whole sheet blindly.
5. Vector vs raster:
   - If vector PDF, extract paths/text first.
   - If raster, OCR + line detection + symbol classification.
6. Coordinate system: page points → real-world feet/inches. Store both.
7. Layers of extraction:
   - Rooms / space names / numbers / areas
   - Wall types / insulation notes if present
   - Fenestration: W/D tags, sizes from schedule cross-ref
   - Ceiling height / volume
   - Orientation / solar exposure
   - Mechanical equipment tags matching schedules
   - Duct mains: size, type (rect/round), CFM callouts
   - Diffusers / grilles / VAV / CAV / fans
   - Pipe mains and sizes
   - Notes, keynotes, spec references
   - Details and section cuts
8. Schedules: equipment, diffuser, damper, motor, electrical MCA/MOP.
9. Confidence score 0–1 per extracted item. Below threshold → RFI candidate.
10. Human verify loop: present overlay (extracted geometry on drawing) conceptually for the app UI.

Never say “I looked at the drawing” without listing:
- sheet ID
- scale used
- what was measured
- confidence
- what could not be read

============================================================
PART 4 — TAKEOFF RULES
============================================================

Produce takeoffs in structured tables:

Category | Item | Tag/Spec | Qty | Unit | Source sheet | Method (counted/measured/calculated) | Confidence | Notes

Units:
- EA, LF, SF, CF, LB, TON, MBH, CFM, GPM, kW, HP, POINT

Rules:
- Measure duct centerline. Add fitting equivalent lengths separately.
- Separate supply / return / OA / exhaust.
- Insulation SF from duct surface + waste factor (state %).
- Equipment from schedule + plan count. Mismatch = audit item.
- Don’t double-count typical details vs plans.
- Revision-aware: takeoff delta between rev clouds.
- Allow assemblies (e.g., “5-ton RTU installed” = unit + curb + disconnect + condensate + gas + flue + controls allowance).

Also output a TRACE: how each quantity was derived.

============================================================
PART 5 — CALCULATION + ANALYSIS RULES
============================================================

For every space and system:

A. Extracted design intent from drawings
B. Calculated required capacity / airflow / OA / water flow
C. Delta and % difference
D. Verdict: OK / MARGINAL / FAIL / INSUFFICIENT DATA
E. Recommended action: none / RFI / redesign / CO / PE review

Always show governing equation in readable form, then substituted numbers, then result with units.

Example pattern:
Q_s = 1.08 × CFM × ΔT
Q_s = 1.08 × 1200 × (75-55) = 25,920 Btuh

Flag typical inconsistencies:
- Schedule tonnage << calculated load
- Supply CFM doesn’t match load at reasonable ΔT
- OA less than ASHRAE 62.1
- Duct velocity excessive
- ESP listed vs estimated fitting pressure
- Equipment weight vs structural note
- Clearance / service access missing
- Conflicting notes between M-sheets and A-sheets
- Addendum not incorporated
- Scale mismatch between related sheets
- Room name on M plan ≠ architectural
- Two different CFM callouts for same diffuser
- Heating coil MBH vs winter load
- Latent load ignored in humid climate
- No diversity applied on large systems or diversity wrongly applied on dedicated spaces

Uncertainty:
If a dimension is unreadable, compute a RANGE (min/likely/max) and mark RFI.

============================================================
PART 6 — PROPOSALS, RFIs, CHANGE ORDERS
============================================================

PROPOSAL must include:
- Project header
- Basis of design / drawings list with dates/revs
- Scope of work
- Assumptions
- Exclusions
- Alternates
- Quantity summary
- Pricing skeleton (unit prices as placeholders unless I provide rates)
- Lead times / schedule
- Taxes, bonds, contingency
- Clarifications that prevent scope fights
- “Open RFIs that affect price”

RFI must include:
- RFI number
- Date
- Spec / sheet / detail / keynote
- Description of conflict or missing info
- Question (single, answerable)
- Suggested resolution
- Cost/schedule impact: Yes/Unknown/No + reason
- Attachments (callout of clouded area)

CHANGE ORDER must include:
- CO number
- Entitlement basis (owner change, hidden condition, document conflict, code interpretation)
- Original contract work
- Proposed work
- Quantity delta
- Cost delta structure (labor, material, equipment, markup)
- Time impact
- Drawing/spec revisions required
- Link back to originating RFI or audit item

Tone: field-ready, contractor + engineer bilingual, no marketing fluff.

============================================================
PART 7 — STANDALONE APP
============================================================

Name working title: LoadSight (changeable).

Platform: Swift / SwiftUI, Xcode, macOS 14+ and iOS 17+. Shared core via Swift Package.

App document model:
Project
  Site / climate
  Code pack
  DrawingSet (files + sheet index + revisions)
  ExtractedModel (spaces, envelope, equipment, distribution)
  CalcModel (loads, air, water)
  Takeoff
  AuditRegister
  Documents (proposal, RFIs, COs)
  AssumptionsLog

Screens:
1. Project dashboard
2. Drawing viewer with overlay + measure tools
3. Space tree + load results
4. Equipment vs load comparison
5. Takeoff spreadsheet
6. Audit / RFI / CO queue
7. Proposal editor
8. Settings: jurisdiction, waste factors, unit costs, design temps

Persistence:
- .loadsight package (directory bundle or sqlite + json + original PDFs)
- Export: XLSX takeoff, PDF proposal, DOCX RFI/CO, JSON for plugin

Deterministic calc core must be unit-testable Swift, not only LLM prose.

LLM role in the app:
- interpret messy notes
- classify symbols
- draft narratives
- propose RFIs
NOT the only source of arithmetic. Arithmetic lives in the calc engine.

============================================================
PART 8 — XCODE PLUGIN / SDK
============================================================

Ship as Swift Package: LoadSightKit

Public API sketch you must flesh out:

public protocol LoadSightServicing {
  func ingestDrawings(_ urls: [URL]) async throws -> DrawingSet
  func extract(_ set: DrawingSet) async throws -> ExtractedModel
  func calculateLoads(_ model: ExtractedModel, config: CalcConfig) async throws -> CalcModel
  func takeoff(_ model: ExtractedModel) async throws -> Takeoff
  func audit(extracted: ExtractedModel, calc: CalcModel) async throws -> AuditRegister
  func draftProposal(_ project: Project) async throws -> ProposalDoc
  func draftRFI(_ item: AuditItem) async throws -> RFIDoc
  func draftCO(_ item: AuditItem, pricing: PricingBook?) async throws -> ChangeOrderDoc
}

Also:
- Combine publishers for progress
- Sendable models
- Background processing
- Privacy: drawings stay on device by default; optional cloud
- App sandbox + security-scoped bookmarks
- Example integration into:
  a) a generic document-based macOS app
  b) an existing contractor estimating app
  c) a field iPad markup app

Provide Package.swift, folder tree, and a 40-line example ContentView that calls the kit.

============================================================
PART 9 — OUTPUT CONTRACT FOR THIS CHAT
============================================================

Respond in this exact order:

SECTION A — Product understanding (short)
SECTION B — Skill catalog table
SECTION C — Full SKILL.md for each required skill
SECTION D — Data models (Swift structs)
SECTION E — Calc engine formulas + validation rules
SECTION F — Blueprint pipeline algorithm
SECTION G — Takeoff + proposal + RFI + CO templates
SECTION H — Standalone app architecture and file tree
SECTION I — LoadSightKit Swift package + plugin usage
SECTION J — Test plan (unit, drawing fixtures, golden calcs)
SECTION K — Next actions I should type in this chat to generate code module-by-module

Use complete, copy-pasteable content. Prefer depth over summaries. If a section is long, continue in the same register rather than collapsing.

When generating skills, write them so I can later paste each SKILL.md into another GPT, Claude, or a local agent and get consistent behavior.

If anything is ambiguous (residential vs commercial, jurisdiction, units IP vs SI), default to:
- mixed residential + light commercial
- IP units (F, Btuh, CFM, inches water)
- US model codes
- California overlay available as a flag
and list those defaults in AssumptionsLog.

Begin now.

## agentMessage

## SECTION A — Product understanding

LoadSight is a mechanical construction-analysis system for GunnAire.  
It uses modular skills, deterministic calculations, drawing extraction, takeoff logic, and document generators.  
It ships as a native SwiftUI app plus **LoadSightKit**, a reusable Swift Package.  
Drawings are source of truth for geometry/tags.  
Calculations are source of truth for load/capacity/code audit.  
Unknowns become assumptions, ranges, or RFIs.  
Arithmetic lives in testable Swift.  
Narratives, RFIs, and proposal language are generated from traceable data.

## SECTION B — Skill catalog table

| Skill | Purpose |
|---|---|
| mechanical-load-core | Heating/cooling load, psychrometrics, zoning, peak/block logic. |
| blueprint-ingest | Read PDFs/images/scans/CAD exports and extract sheets, scale, geometry, tags, notes. |
| quantity-takeoff | Count and measure equipment, duct, pipe, insulation, grilles, controls, hangers. |
| drawing-vs-calc-audit | Compare drawings against calculations and produce discrepancy register. |
| proposal-builder | Generate contractor-ready proposal scopes, exclusions, alternates, and pricing skeleton. |
| rfi-generator | Draft formal RFIs from missing data, conflicts, unreadable drawings, and audit failures. |
| change-order-generator | Draft CO narratives, quantity deltas, entitlement basis, pricing structure, schedule impact. |
| equipment-schedule-parser | Parse HVAC schedules and normalize tons, CFM, MBH, ESP, MCA/MOP, weights, dimensions. |
| code-compliance-check | Check ventilation, access, energy, duct velocity, outdoor air, economizer/code triggers. |
| xcode-plugin-bridge | Expose skills through Swift protocols, local REST, async APIs, and plugin-safe models. |
| standalone-app-shell | Define LoadSight app screens, project format, persistence, exports, and workflow. |
| psychrometrics-core | Shared moist-air formulas and validation routines. |
| duct-sizer | Equal-friction/static/velocity duct sizing with pressure-loss audit. |
| fuel-gas-core | Fuel input, gas demand, conceptual pipe sizing, combustion-air/venting checklist. |
| manual-j-residential | Residential Manual J style workflow wrapper. |
| title-24-ca | California overlay for Title 24/CMC when jurisdiction flag is CA. |

ACCA identifies Manual J as the residential load standard, Manual S as equipment selection, and Manual D as residential duct design; the system should keep those roles separate. citeturn240918view0turn240918view1turn240918view2

## SECTION C — Full SKILL.md for each required skill

### `mechanical-load-core/SKILL.md`

```md
---
name: mechanical-load-core
description: Calculate heating/cooling loads, psychrometrics, zoning, peak/block loads, airflow, and capacity checks when asked for Manual J, Manual N, ASHRAE loads, CFM, Btuh, tonnage, ventilation, infiltration, envelope, sensible, latent, or load audit.
---

Use IP units by default.

Create an AssumptionsLog before calculating.

Record:
- Jurisdiction assumed.
- Climate zone assumed.
- Indoor heating design temperature.
- Indoor cooling dry-bulb and relative humidity.
- Outdoor winter 99% design temperature.
- Outdoor summer 1% dry-bulb and coincident wet-bulb.
- Building type.
- Occupancy type.
- Safety factor.
- Source of every dimension.
- Source of every U-factor.
- Source of every airflow.
- Source of every internal gain.

Never invent missing geometry as fact.

Classify every input as EXTRACTED, USER-PROVIDED, CODE-DEFAULT, ENGINEERING-ASSUMPTION, or RFI-REQUIRED.

Calculate envelope loads using:
Q = U × A × ΔT

Calculate total assembly U-factor using:
U = 1 / R_total

Calculate sensible air load using:
Q_s = 1.08 × CFM × ΔT
Use this only when standard-air assumptions are acceptable.

Calculate latent load using:
Q_l = 0.68 × CFM × ΔGrains
Use this only when humidity difference is in grains/lb dry air.

Calculate total air load using:
Q_t = 4.5 × CFM × Δh
Use enthalpy in Btu/lb dry air.

Calculate SHR using:
SHR = Q_s / Q_t

Reject impossible SHR values below 0 or above 1 unless clearly labeled as data error.

Calculate ventilation outdoor air from applicable code or standard:
V_oz = R_p × P_z + R_a × A_z
Apply zone and system ventilation effectiveness when available.

Calculate infiltration as ACH, CFM, or method-specific leakage model.
Show method used.

Separate:
- Room load.
- Zone load.
- Block load.
- Coil load.
- Equipment capacity.
- Delivered capacity.

Do not size equipment directly from nominal tons.

Compare calculated load to selected equipment capacity at actual design conditions.

Flag:
- oversized equipment.
- undersized equipment.
- latent mismatch.
- airflow mismatch.
- heating output mismatch.
- missing design conditions.
- missing envelope values.
- missing duct location/leakage assumptions.
- peak-vs-block confusion.

Return:
- SpaceLoad table.
- ZoneLoad table.
- SystemLoad table.
- Equations used.
- Substituted numbers.
- Result with units.
- AssumptionsLog.
- RFI candidates.
- PEReview items.
```

### `blueprint-ingest/SKILL.md`

```md
---
name: blueprint-ingest
description: Ingest construction drawings, PDFs, scans, photos, CAD exports, mixed scales, title blocks, schedules, notes, tags, rooms, ducts, pipes, and mechanical symbols when asked to read drawings, plans, blueprints, takeoff, or compare sheets.
---

Treat drawings as source of truth for geometry and tags.

Index every file.

For each sheet extract:
- Sheet ID.
- Sheet title.
- Discipline.
- Revision number.
- Revision date.
- Addenda.
- Scale text.
- Graphic scale.
- North arrow.
- Title block.
- Drawing date.
- Drawn by.
- Checked by.
- Project name.
- Project address.

Detect whether sheet is vector, raster, or mixed.

For vector PDF:
- Extract text.
- Extract paths.
- Extract linework.
- Extract symbols.
- Extract dimensions.
- Preserve page coordinates.

For raster or photo:
- Correct rotation.
- Correct perspective if photographed.
- Detect borders.
- OCR text.
- Detect lines.
- Detect symbols.
- Detect scale bar.
- Classify rooms, walls, openings, tags, ducts, pipe, equipment.

Detect scale in this order:
1. Explicit written scale.
2. Graphic scale bar.
3. Known dimension string.
4. Known object check.
5. User calibration.

Never apply one scale to a whole sheet when plan, enlarged plan, and detail scales differ.

Store coordinates as:
- pagePointX.
- pagePointY.
- realWorldX.
- realWorldY.
- scaleContextID.

Extract:
- Rooms.
- Space names.
- Space numbers.
- Room boundaries.
- Ceiling heights.
- Wall types.
- Door tags.
- Window tags.
- Shafts.
- Mechanical rooms.
- Equipment tags.
- Duct mains.
- Duct sizes.
- Duct CFM callouts.
- Diffusers.
- Grilles.
- VAV/CAV boxes.
- Fans.
- Pipe mains.
- Pipe sizes.
- Notes.
- Keynotes.
- Details.
- Section cuts.
- Schedules.

Assign confidence 0.00 to 1.00 to every item.

Below 0.75 confidence, create RFI candidate or human-verification task.

Always report:
- Sheet ID.
- Scale used.
- What was measured.
- Confidence.
- What could not be read.
```

### `quantity-takeoff/SKILL.md`

```md
---
name: quantity-takeoff
description: Produce mechanical quantity takeoffs for equipment, duct, fittings, pipe, valves, insulation, curbs, grilles, VAV boxes, controls, hangers, sheet metal, and assemblies when asked for estimate quantities or takeoff.
---

Use this table format:
Category | Item | Tag/Spec | Qty | Unit | Source sheet | Method | Confidence | Notes

Use units:
EA, LF, SF, CF, LB, TON, MBH, CFM, GPM, kW, HP, POINT.

Separate:
- Supply air.
- Return air.
- Outdoor air.
- Exhaust air.
- Relief air.
- Condensate.
- Heating water.
- Chilled water.
- Refrigerant.
- Natural gas.
- Controls.

Measure duct by centerline length.

Calculate rectangular duct surface:
SF = 2 × (width + height) × length / 12

Calculate round duct surface:
SF = π × diameter × length / 12

Add fitting equivalent lengths separately.

Do not double-count fittings drawn in plan and repeated in details.

Count equipment from plans and schedules.
If plan count differs from schedule count, create audit item.

Apply waste factors only when stated.
Default duct insulation waste = 10% assumption.
Default pipe insulation waste = 7% assumption.
Default sheet metal fabrication waste = 10% assumption.

Trace every quantity:
- Source sheet.
- View/detail.
- Scale.
- Measured segment IDs.
- Count method.
- Formula.
- Waste factor.
- Exclusions.

Allow assemblies:
- RTU installed.
- Split system installed.
- VAV terminal installed.
- Exhaust fan installed.
- Gas furnace installed.
- Unit heater installed.

Assembly quantities must expand into included subitems.
```

### `drawing-vs-calc-audit/SKILL.md`

```md
---
name: drawing-vs-calc-audit
description: Compare extracted drawing design against calculated loads, airflow, equipment, ventilation, duct, pipe, access, code, and structural coordination when asked to audit, verify, compare, find conflicts, or check plans.
---

For every system compare:
A. Extracted design intent.
B. Calculated requirement.
C. Delta.
D. Percent difference.
E. Verdict.
F. Recommended action.

Verdicts:
OK.
MARGINAL.
FAIL.
INSUFFICIENT DATA.

Recommended actions:
none.
RFI.
redesign.
change order.
PE review.

Flag:
- Schedule tonnage below calculated load.
- Schedule tonnage above allowable oversizing range.
- Supply CFM inconsistent with sensible load.
- Outdoor air below required ventilation.
- Duct velocity excessive.
- ESP too low for estimated pressure loss.
- Equipment weight exceeds structural note.
- Service clearance missing.
- Two different CFM callouts for same diffuser.
- Heating coil MBH below winter load.
- Latent load ignored.
- Diversity missing or misapplied.
- Scale mismatch.
- Addendum not incorporated.
- M-sheet conflicts with A-sheet.
- Equipment tag on plan missing from schedule.
- Schedule item missing from plan.

Return AuditRegister with:
- auditID.
- severity.
- sourceSheets.
- extractedValue.
- calculatedValue.
- delta.
- equation.
- assumption.
- recommendation.
- linkedRFI.
- linkedCO.
```

### `proposal-builder/SKILL.md`

```md
---
name: proposal-builder
description: Generate contractor-ready mechanical proposals with scope, inclusions, exclusions, assumptions, alternates, quantity summary, pricing skeleton, schedule, taxes, bonds, contingency, and open RFIs when asked for proposal, bid, estimate, or scope letter.
---

Write in contractor + engineer bilingual tone.

Include:
- Project header.
- Customer/GC.
- Project name.
- Address.
- Drawing basis.
- Addenda basis.
- Scope of work.
- Inclusions.
- Exclusions.
- Assumptions.
- Alternates.
- Quantity summary.
- Pricing skeleton.
- Taxes.
- Bonds.
- Contingency.
- Schedule.
- Lead times.
- Clarifications.
- Open RFIs affecting price.
- Proposal validity period.

Keep plumbing and electrical excluded unless expressly included.

Include mechanical coordination notes when other trades affect HVAC.

Do not price without rates.
Use placeholders unless pricing book exists.

State every open risk clearly.

Do not bury exclusions in fine print.
```

### `rfi-generator/SKILL.md`

```md
---
name: rfi-generator
description: Draft formal RFIs from missing dimensions, drawing conflicts, code conflicts, unreadable notes, equipment mismatches, load mismatches, or unclear scope when asked for RFI, clarification, question, conflict, or missing information.
---

Create one answerable question per RFI.

Include:
- RFI number.
- Date.
- Project.
- To.
- From.
- Spec reference.
- Sheet reference.
- Detail reference.
- Keynote reference.
- Description.
- Question.
- Suggested resolution.
- Cost impact.
- Schedule impact.
- Attachments.
- Required response date.

Use field-ready language.

Do not combine unrelated conflicts.

If cost/schedule impact is unknown, state Unknown and explain why.

If unresolved item affects price, mark Proposal Impact = Yes.
```

### `change-order-generator/SKILL.md`

```md
---
name: change-order-generator
description: Draft change orders with entitlement basis, original work, proposed work, quantity delta, cost delta, markup, schedule impact, and linked RFI/audit items when asked for CO, change order, extra work, added cost, or revision impact.
---

Include:
- CO number.
- Date.
- Project.
- Customer/GC.
- Entitlement basis.
- Original contract scope.
- Proposed revised scope.
- Drawing/spec revision.
- Originating RFI or audit item.
- Quantity delta.
- Labor cost placeholder.
- Material cost placeholder.
- Equipment cost placeholder.
- Subcontractor cost placeholder.
- Markup placeholder.
- Tax placeholder.
- Bond placeholder.
- Total placeholder.
- Time impact.
- Exclusions.
- Required approval language.

Classify entitlement:
- Owner change.
- Hidden condition.
- Document conflict.
- Code interpretation.
- Design revision.
- Field condition.
- Schedule acceleration.
```

### `equipment-schedule-parser/SKILL.md`

```md
---
name: equipment-schedule-parser
description: Parse HVAC equipment schedules from drawings and normalize tags, tons, CFM, MBH, EWT/LWT, ESP, MCA/MOP, weights, dimensions, voltage, phase, accessories, and notes.
---

Find schedules on all M, P, E, and equipment sheets.

Parse:
- Equipment tag.
- Equipment type.
- Manufacturer.
- Model.
- Quantity.
- Cooling total capacity.
- Cooling sensible capacity.
- Heating capacity.
- Furnace input.
- Furnace output.
- CFM.
- Outdoor air CFM.
- ESP.
- EWT.
- LWT.
- GPM.
- Voltage.
- Phase.
- MCA.
- MOP.
- Weight.
- Dimensions.
- Sound.
- Accessories.
- Notes.

Normalize units.

Cross-reference:
- Plan tags.
- Details.
- Electrical schedules.
- Structural notes.
- Controls drawings.

Flag:
- missing plan tag.
- missing schedule item.
- duplicate tag.
- impossible capacity.
- MCA/MOP missing.
- weight missing.
- ESP missing.
- OA missing.
```

### `code-compliance-check/SKILL.md`

```md
---
name: code-compliance-check
description: Check mechanical code, ventilation, energy, access clearances, outdoor air, duct velocity, economizer triggers, combustion air, venting, and jurisdiction overlays when asked for code, compliance, IMC, UMC, ASHRAE, Title 24, CMC, SMACNA, NFPA, IPC, UPC, or inspection issue.
---

Default jurisdiction = US model code unless user supplies location.

Record jurisdiction as ASSUMPTION until confirmed.

Check:
- IMC mechanical safety.
- UMC when jurisdiction uses UMC.
- ASHRAE 62.1 nonresidential ventilation.
- ASHRAE 62.2 residential ventilation.
- ASHRAE 90.1 energy triggers.
- ACCA Manual J/S/D/T workflow.
- SMACNA duct construction.
- IFGC/NFPA 54 fuel gas.
- IPC/UPC plumbing when mechanical/process drawings require coordination.
- IBC structural/mechanical equipment support.
- California Title 24/CMC when CA flag is true.

Do not quote code text beyond short fair-use snippets.
Summarize requirement and cite source/section placeholder.

Return:
- Compliance item.
- Requirement.
- Source.
- Extracted condition.
- Verdict.
- Required action.
- PE/AHJ review flag.
```

### `xcode-plugin-bridge/SKILL.md`

```md
---
name: xcode-plugin-bridge
description: Expose LoadSight skills as Swift protocols, async APIs, Sendable data models, local REST calls, Combine progress streams, and plugin-safe SDK components for any Xcode app.
---

Build as Swift Package named LoadSightKit.

Expose deterministic calculation APIs.

Keep LLM calls optional.

Keep drawings on device by default.

Use async/await.

Mark public models Sendable.

Publish progress updates with AsyncStream and Combine.

Support:
- macOS document apps.
- contractor estimating apps.
- iPad markup apps.
- local REST service.
- offline deterministic mode.
- optional cloud processing.

Never require app-specific UI.

Separate:
- LoadSightCore.
- LoadSightIngest.
- LoadSightCalc.
- LoadSightTakeoff.
- LoadSightAudit.
- LoadSightDocuments.
- LoadSightLLMBridge.
```

### `standalone-app-shell/SKILL.md`

```md
---
name: standalone-app-shell
description: Define the native LoadSight macOS and iOS app shell, project file format, screens, persistence, exports, settings, and user workflow when asked for app, Xcode project, SwiftUI, screens, UI, or build plan.
---

Use SwiftUI.

Target macOS 14+ and iOS 17+.

Use shared Swift Package core.

Create document-based project package:
.loadsight/
  project.json
  drawings/
  extracted/
  calcs/
  takeoffs/
  audits/
  documents/
  assumptions/
  overlays/

Screens:
- Project dashboard.
- Drawing viewer.
- Overlay and measure tools.
- Space tree.
- Load results.
- Equipment comparison.
- Takeoff spreadsheet.
- Audit queue.
- RFI queue.
- Change order queue.
- Proposal editor.
- Settings.

Exports:
- XLSX takeoff.
- PDF proposal.
- DOCX RFI.
- DOCX CO.
- JSON project.
- CSV quantities.

Keep deterministic calculations unit-testable.
Use LLM only for interpretation, classification, and drafting.
```

## SECTION D — Data models

```swift
public struct Project: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var site: Site
    public var codePack: CodePack
    public var drawingSet: DrawingSet
    public var extractedModel: ExtractedModel?
    public var calcModel: CalcModel?
    public var takeoff: Takeoff?
    public var auditRegister: AuditRegister?
    public var documents: ProjectDocuments
    public var assumptionsLog: [Assumption]
}

public struct Site: Codable, Sendable {
    public var address: String?
    public var jurisdiction: String?
    public var climateZone: String?
    public var indoorHeatingF: Double
    public var indoorCoolingF: Double
    public var indoorCoolingRH: Double
    public var outdoorHeating99F: Double?
    public var outdoorCooling1F: Double?
    public var outdoorWetBulbF: Double?
}

public struct CodePack: Codable, Sendable {
    public var modelCode: String
    public var mechanicalCodeEdition: String?
    public var energyCodeEdition: String?
    public var fuelGasCodeEdition: String?
    public var californiaTitle24Enabled: Bool
    public var localAmendments: [String]
}

public struct DrawingSet: Codable, Sendable {
    public var files: [DrawingFile]
    public var sheets: [Sheet]
    public var revisions: [Revision]
}

public struct Sheet: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sheetNumber: String
    public var title: String
    public var discipline: Discipline
    public var scaleContexts: [ScaleContext]
    public var northAngleDegrees: Double?
    public var confidence: Double
}

public enum Discipline: String, Codable, Sendable {
    case architectural, structural, mechanical, plumbing, electrical, fireProtection, civil, unknown
}

public struct ScaleContext: Codable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var pageRect: Rect
    public var feetPerPoint: Double
    public var source: ScaleSource
    public var confidence: Double
}

public enum ScaleSource: String, Codable, Sendable {
    case writtenScale, graphicScale, dimensionString, knownObject, userCalibration
}

public struct ExtractedModel: Codable, Sendable {
    public var spaces: [Space]
    public var envelopeItems: [EnvelopeItem]
    public var equipment: [Equipment]
    public var ducts: [DuctSegment]
    public var pipes: [PipeSegment]
    public var terminals: [AirTerminal]
    public var notes: [DrawingNote]
}

public struct Space: Codable, Identifiable, Sendable {
    public var id: UUID
    public var number: String?
    public var name: String
    public var areaSF: Double?
    public var volumeCF: Double?
    public var ceilingHeightFT: Double?
    public var sourceSheet: String
    public var confidence: Double
}

public struct Equipment: Codable, Identifiable, Sendable {
    public var id: UUID
    public var tag: String
    public var type: String
    public var coolingTotalBtuh: Double?
    public var coolingSensibleBtuh: Double?
    public var heatingOutputBtuh: Double?
    public var heatingInputBtuh: Double?
    public var airflowCFM: Double?
    public var outdoorAirCFM: Double?
    public var espInWC: Double?
    publi

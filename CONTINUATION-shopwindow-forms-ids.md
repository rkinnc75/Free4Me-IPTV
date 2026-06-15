# Continuation Summary — Shopwindow forms & IDs task

**Date:** 2026-06-15
**Asked:** "Find the prior task that dealt with Shopwindow and the forms and IDs; where are the files?"

## What the task was

Populating the integration-settings table **`intstn_attrs`** with **Shopwindow form / appointment-type UUIDs** — mapping each client/location's `*.shopwindow.io` domain (`host`) to its form IDs so `SendShopwindowLead` can submit leads via `forms[].id` matched by form name.

Origin work lives in two **Cursor** conversations (not Claude Code):
- `492282f9-4b2b-4514-8638-be8de608cd2c` — origin; built `populate.py`, scraped UUIDs from `*.shopwindow.io/#crm.forms2.manager`, extended to client **483**.
- `7f0b6f83-b564-45c5-bbe6-96bed3714fa1` — follow-up tied to **SYSOPS-2482**; Waggles domains, before/after `intstn_attrs` preview, caught client 574 row with empty `host`.

Related Jira: **PO-11634** (enrich Shopwindow leads with pet DOB/color).

## Where the files are

**All in `~/git/ssdriver`.** The full populate tooling is on branch
**`SYSOPS-2464-shopwindow-intstn-attrs-tooling`** (local + `origin`) — NOT on the
current `PO-11660-…` branch. To use it:

```
git checkout SYSOPS-2464-shopwindow-intstn-attrs-tooling
```

### Core tooling (SYSOPS-2464 branch)
- `scripts/shopwindow_populate_intstn_attrs/populate.py` — builds `intstn_attrs` preview / commit / revert SQL
- `scripts/shopwindow_populate_intstn_attrs/examples/petland_pensacola_ftwalton.json` — input format example
- `scripts/shopwindow_populate_intstn_attrs/README.md`
- `scripts/shopwindow_list_forms/list_forms.js` — scrapes form UUIDs from `*.shopwindow.io/#crm.forms2.manager`
- `.env.shopwindow.example` — credentials template
- `docs/Shopwindow-Populate-Intstn-Attrs.md`, `docs/Shopwindow-Form-UUID-Scraper.md` — runbooks
- `ssdriver/tests/test_tasks/test_shopwindow.py`, `ssdriver/tests/test_shopwindow_billing.py`

### Already on current branch
- `scripts/shopwindow_list_appointment_types/` — JS scraper + `examples/waggles_appointment_type_ids_{preview,commit}.sql`
- `docs/Shopwindow-Appointment-Type-UUID.md`, `docs/Shopwindow-Integration-Tooling.md`
- `.ai/shopwindow_populate_intstn_attrs.plan.md`

### Backend (all branches)
- `ssdriver/ssdriver/task_manager/tasks/shopwindow.py` — `SendShopwindowLead`, uses `forms[].id`
- `ssdriver/ssdriver/models/lead_conversation.py`, `ssdriver/ssdriver/models/entity_location.py`

## Notes / gotchas
- On the current branch, `scripts/shopwindow_populate_intstn_attrs/` and
  `scripts/shopwindow_list_forms/` are **empty shells** (only `__pycache__` /
  `node_modules`); source exists only on the SYSOPS-2464 branch.
- A temporary `git checkout <branch> -- …` restore of those files onto the current
  branch was performed and then **fully undone** — current branch is unchanged.

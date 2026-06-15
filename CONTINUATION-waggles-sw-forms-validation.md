# Continuation — Validate Waggles Shopwindow form IDs + appointment IDs

**Date:** 2026-06-15
**Task:** For 9 Waggles `*.shopwindow.io` accounts, read the `intstn_attrs` rows and
validate that the Shopwindow (SW) **form ID** values are populated correctly, and the
**appointment_type_id** too. Check every account even if the DB value is NULL.

## The 9 hosts
wagglesroanoke, wagglesportcharlotte, wagglesfortmyers, wagglesraleigh,
wagglesgreensboro, wagglescharlotte, wagglesdayton, waggleskendall, wagglesduluth
(stored in DB as `https://<host>.shopwindow.io`)

## Data model (confirmed)
- Table: `cdata_core.integration_settings`
- Shopwindow integration: `intstn_integration_id = 18`
- JSONB col `intstn_attrs` → `locations[]`; each location object has:
  `host`, `name`, `appointment_type_id`, and `forms[]` (each form: `name`, `id`).
- `SendShopwindowLead` (`ssdriver/task_manager/tasks/shopwindow.py`) submits leads via
  `forms[].id` matched by form name. So "correct" = DB `forms[].id` / `appointment_type_id`
  match the live UUIDs scraped from each `*.shopwindow.io` site.

## Two sources to compare
1. **DB (current values)** — read-only SELECT below.
2. **Live SW sites (truth)** — scrape UUIDs:
   - Form UUIDs: `scripts/shopwindow_list_forms/list_forms.js` (source only on branch
     `SYSOPS-2464-shopwindow-intstn-attrs-tooling`; empty shell on other branches).
   - Appointment-type UUIDs: `scripts/shopwindow_list_appointment_types/` (on current branch).
   - Both need creds in `.env.shopwindow` (template `.env.shopwindow.example` on SYSOPS-2464).
   - A prior scrape of appointment_type_id (2026-06-02) for all 9 is in
     `scripts/shopwindow_list_appointment_types/examples/waggles_appointment_type_ids.json`
     — usable as a reference, but re-scrape to validate "currently correct".

## DB access — THE GOTCHA (why this session stalled)
- pg-licht / pg-licht-select MCP servers were configured but came up with **zero callable
  tools** because the podb01 tunnel was DOWN at session start. MCP servers only spawn at
  session start — can't re-register mid-session. **Fix: open tunnel FIRST, then start Claude
  Code**, so pg-licht-select `runSelect` registers against a reachable DB.
- `DATABASE_URL` (in `~/.config/pinogy-mcp.env`) → `127.0.0.1:44432` → `10.10.53.13:5432`
  db `podb01`, user `podb_readonly`. Requires SSH tunnel on 44432.
- Use the **`mt22-prod`** tunnel: `ssh -fN mt22-prod` (forwards 44432→10.10.53.13:5432 from
  source 10.10.53.15, which pg_hba allows).
  Do NOT use `db0-replica` — it forwards to the same DB but the connection arrives FROM
  10.10.53.13 (itself) and pg_hba REJECTS `podb_readonly` from there
  (`no pg_hba.conf entry for host 10.10.53.13`).
- psycopg2 fallback gotcha: `DATABASE_URL` has a `uselibpqcompat` query param psycopg2
  can't parse — strip all query params except `sslmode`. (MCP `runSelect` handles the URL natively.)

## The read-only validation query
```sql
SELECT s.integration_setting_id, s.intstn_client_id, (loc.idx-1) AS loc_idx,
       loc.obj->>'host' AS host, loc.obj->>'name' AS name,
       loc.obj->>'appointment_type_id' AS appt_id, loc.obj->'forms' AS forms
FROM cdata_core.integration_settings s,
     LATERAL jsonb_array_elements(s.intstn_attrs->'locations') WITH ORDINALITY AS loc(obj, idx)
WHERE s.intstn_integration_id = 18 AND NOT s.intstn_is_mfd
  AND loc.obj->>'host' = ANY(ARRAY[
    'https://wagglesroanoke.shopwindow.io','https://wagglesportcharlotte.shopwindow.io',
    'https://wagglesfortmyers.shopwindow.io','https://wagglesraleigh.shopwindow.io',
    'https://wagglesgreensboro.shopwindow.io','https://wagglescharlotte.shopwindow.io',
    'https://wagglesdayton.shopwindow.io','https://waggleskendall.shopwindow.io',
    'https://wagglesduluth.shopwindow.io'])
ORDER BY host;
```
NB: an account with NULL/empty form IDs may have NO matching location row (or a null
`forms`) — reconcile the returned rows against the full 9-host list so missing accounts are
reported, not silently dropped. Watch for client 574 (PORTCHAR) which historically had an
empty `host` in one row.

## Next steps after restart
1. `ssh -fN mt22-prod` (verify `lsof -iTCP:44432 -sTCP:LISTEN`), then launch Claude Code.
2. Confirm `mcp__pg-licht-select__runSelect` is now callable (ToolSearch `select:...`).
3. Run the query → record DB `forms[].id` + `appointment_type_id` per host.
4. Scrape live SW sites for form + appointment UUIDs; diff DB vs live; flag mismatches,
   NULLs, and any host with no DB row.

## State left clean
- No tunnels left running (db0-replica tunnel killed; 44432 free).
- No DB writes attempted. Read-only throughout.

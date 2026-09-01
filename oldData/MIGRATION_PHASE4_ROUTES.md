# Chess Manager — API Reference / Route Matrix (Migration Phase 4)

A scan of every API call, controller-equivalent, data-access route, auth
endpoint, and validation path in the repository, compiled into an endpoint
matrix.

---

## 0. Critical Finding: Architectural Nature of the "API"

**There are no in-repo controller files, router definitions, server route
tables, OpenAPI schemas, or custom middleware.** Chess Manager is a **thin
Supabase client** (a Flutter app). All "routes" resolve to one of two
out-of-process API surfaces provided by the Supabase platform:

1. **PostgREST REST API** — `POST {SUPABASE_URL}/rest/v1/{table}` (and
   `GET`/`PATCH`/`DELETE` variants). Invoked via the `supabase_flutter` Dart
   client (`.from(table).select/upsert/update/delete/eq/inFilter/order/single`).
2. **Supabase Auth / GoTrue API** — `POST {SUPABASE_URL}/auth/v1/...` for
   `signInWithPassword`, `signInWithOtp`, `signOut`, `updateUser`,
   `onAuthStateChange`.

Because the client routes through PostgREST, **every table operation goes
through the same nominal endpoint** `{SUPABASE_URL}/rest/v1/{table}` — the
distinguishing fields are the HTTP method (mapped from `select`/`upsert`/
`update`/`delete`) and the PostgREST query/body parameters.

### The "middleware" & authorization pipeline
Supplied **entirely by Supabase**, not by this repo:
- **RLS (Row-Level Security) policies** decide row visibility/mutation per
  request (the authorization layer).
- **JWT/anon-key auth header** (`apikey` + `Authorization: Bearer <JWT>`)
  is attached by the `supabase_flutter` client for every request.
- **School scoping** is enforced in-app via a `school_id` filter on every
  query (`SupabaseDb` caches `_schoolId` at `init()`/`initPublic()`), while
  the server re-checks it against RLS.
- **No client-side HTTP middleware**: the code does not intercept requests;
  the client SDK handles headers, session refresh, and error propagation
  (thrown exceptions are caught per-call).

### Roles / permissions (defined in Supabase, referenced in code)
| Role (stored in `profiles.role`) | Capability |
|----------------------------------|-----------|
| `player` | Default. Read/participate in their school's data |
| `school_admin` | Manage accounts (view profiles, change roles within their school) |
| `super_admin` | Full admin (RLS predicates include it; cannot be role-edited) |
| anon (unauthenticated) | Public read of `schools` by code + public read of their school's players/tournaments/teams (`initPublic`) |

RLS policy snippets referenced in source (`accounts_page.dart`):
```
create policy "admins read school profiles" on profiles for select
  using (school_id = my_school_id()
         and (my_role() = 'school_admin' or my_role() = 'super_admin'));
create policy "admins update school profiles" on profiles for update
  using (school_id = my_school_id()
         and (my_role() = 'school_admin' or my_role() = 'super_admin'));
```
(Other policies — public `schools`/`profiles` read, per-school isolation on
`players`/`teams`/`tournaments` — are referenced but not embedded in source.)

---

## 1. Endpoint Matrix

Legend — HTTP method mapping from the Dart client: `select` → `GET`,
`upsert` → `POST` (Prefer: resolution=merge-duplicates), `update` → `PATCH`,
`delete` → `DELETE`, `single` adds `Accept: application/vnd.pgrst.object+json`.

### 1.1 Authentication & Session Endpoints

| # | Endpoint (GoTrue `/auth/v1`) | HTTP | Auth req | Request payload | Underlying function | Response / handling |
|---|------------------------------|------|----------|-----------------|---------------------|---------------------|
| A1 | `POST /auth/v1/token?grant_type=password` | **signInWithPassword** | anon key (no session) | `{email, password}` (trimmed email, raw password) | `_LoginScreenState._signIn()` → then `SupabaseDb.init()` resolves `school_id` | **Success**: session stored; `onLoginSuccess()` → `MainScreen`. **Failure**: `AuthException.e.message` shown in login form |
| A2 | `POST /auth/v1/otp` (magic link) | **signInWithOtp** | anon key | `{email}` | `_AccountsPageState._invite()` (admin invite flow) | **Success**: email magic link sent; dialog closed, "Invitation sent" SnackBar. **Failure**: `AuthException`/error shown in dialog |
| A3 | `POST /auth/v1/logout` | **signOut** | valid session | — | `_MainScreenState._signOut()` + `SupabaseDb.reset()` (clears cached `_schoolId`) | **Success**: session cleared → `_AuthGate` shows `PublicScreen`. **Failure**: not surfaced (fire-and-forget in `_signOut`) |
| A4 | `POST /auth/v1/user` (update, password-only) | **updateUser** | valid session | `UserAttributes(password: newPassword)` validated by form (min length in widget, confirm-match enforced) | `_ChangePasswordDialogState._save()` | **Success**: `_success=true` state. **Failure**: `AuthException.e.message` shown |
| A5 | `onAuthStateChange` (real-time stream) | **event stream** | session | — | `_AuthGateState.initState()` | Stream of `AuthState` → toggles between `PublicScreen` / `MainScreen`; also drives sign-out UI automatically |
| A6 | `GET /auth/v1/user` (in-app session) | **currentUser / currentSession** | anon key | — | Used throughout (`_AuthGate`, `SupabaseDb.init`, `AccountsPage`) | Local-only, offline-safe session read; **no network call** |

### 1.2 Data Endpoints (PostgREST `/rest/v1/{table}`)

All data endpoints require a valid session (JWT) **except** those marked
`initPublic`/read-only-for-anon.

#### players

| # | Route | HTTP | Auth req | Query/body params (schema) | Service function | Operations |
|---|-------|------|----------|----------------------------|------------------|-----------|
| P1 | `/rest/v1/players?select=*&school_id=eq.{sid}&order=last_name` | GET | session (RLS: school scope) | `school_id` eq filter, `order=last_name` | `SupabaseDb.loadPlayers()` | Reads all players for the school, orders by last name, maps snake_case→`Player` model |
| P2 | `/rest/v1/players` (bulk upsert) | POST | session (RLS) | Body = array of `{id, school_id, first_name, last_name, blitz_rating, rapid_rating, email, phone, title, gender, member_status, college, program, wins, losses, draws, is_active, created_at}`; empty list is a no-op | `SupabaseDb.savePlayers(players)` | Upsert (insert+update) of many players |
| P3 | `/rest/v1/players?id=eq.{id}` (single upsert) | POST | session | Body = single player row | `SupabaseDb.savePlayer(p)` (delegates to `savePlayers([p])`) | Upsert one player (rating updates, profile edits) |
| P4 | `/rest/v1/players?id=eq.{id}` | DELETE | session (RLS) | `id` eq filter | `SupabaseDb.deletePlayer(id)` | Hard-deletes a player |

#### teams (reusable rosters)

| # | Route | HTTP | Auth req | Query/body params | Service function | Operations |
|---|-------|------|----------|-------------------|------------------|-----------|
| T1 | `/rest/v1/teams?select=*&school_id=eq.{sid}&order=name` | GET | session | `school_id` eq, `order=name` | `SupabaseDb.loadTeams()` | Read saved rosters; maps to `RosterTeam` |
| T2 | `/rest/v1/teams` (bulk upsert) | POST | session | Body = `[{id, school_id, name, player_ids}]` (player_ids jsonb array) | `SupabaseDb.saveTeams(teams)` | Upsert saved teams |
| T3 | `/rest/v1/teams?id=eq.{id}` | DELETE | session | `id` eq | `SupabaseDb.deleteTeam(id)` | Hard-delete a saved roster |

#### tournaments (multi-table transaction)

| # | Route | HTTP | Auth req | Query/body params | Service function | Operations |
|---|-------|------|----------|-------------------|------------------|-----------|
| X1 | `/rest/v1/tournaments?select=*&school_id=eq.{sid}&order=created_at` | GET | session / anon(read) | `school_id` eq, `order=created_at` | `SupabaseDb.loadTournaments(players)` (part 1 of 3) | Read tournament metadata |
| X2 | `/rest/v1/tournament_players?select=*&tournament_id=in.({tIds})` | GET | session / anon | `tournament_id` `in` filter (bulk) | `SupabaseDb.loadTournaments` (part 2) | Read roster snapshots for all tournaments at once |
| X3 | `/rest/v1/matches?select=*&tournament_id=in.({tIds})&order=round.asc,board.asc` | GET | session / anon | `tournament_id` `in`, `order=round,board` | `SupabaseDb.loadTournaments` (part 3) | Read all matches for all tournaments; joined in Dart to rebuild `rounds` |
| X4 | `/rest/v1/tournaments` (upsert metadata) | POST | session | Body = `{id, school_id, name, format, status, rating_type, is_rated, current_round, rating_snapshot, wdl_snapshot, tiebreak_results, created_at, teams(jsonb), max_boards, team_pairings(jsonb)}` | `SupabaseDb.saveTournament(t)` (step 1 of 3) | Upsert tournament metadata + jsonb snapshots |
| X5 | `/rest/v1/tournament_players` (upsert roster) | POST | session | Body = `[{tournament_id, player_id, blitz_rating, rapid_rating}]` (skipped if roster empty) | `SupabaseDb.saveTournament` (step 2) | Upsert roster snapshot |
| X6 | `/rest/v1/matches` (upsert matches) | POST | session | Body = `[{id, tournament_id, round, board, white_player_id, black_player_id, result, white_rating_delta, black_rating_delta}]` (skipped if no matches) | `SupabaseDb.saveTournament` (step 3) | Upsert all matches; writes per-match rating deltas |
| X7 | `/rest/v1/tournaments?id=eq.{id}` | DELETE | session | `id` eq | `SupabaseDb.deleteTournament(id)` | Hard-delete; **server cascades** to `tournament_players` + `matches` |
| X8 | `saveTournaments(list)` | — | session | loop of X4–X6 | `SupabaseDb.saveTournaments(tournaments)` | Sequential saves (bulk backup-restore path) |

#### profiles / schools (auth context)

| # | Route | HTTP | Auth req | Query/body params | Service function | Operations |
|---|-------|------|----------|-------------------|------------------|-----------|
| PR1 | `/rest/v1/profiles?select=school_id&id=eq.{uid}` (single) | GET | session | `id` eq + `single` (expects exactly 1 row, throws if 404/ambiguous) | `SupabaseDb.init()` | Resolve & cache current user's `school_id`; throws if profile missing / no `school_id` |
| PR2 | `/rest/v1/schools?select=id&code=eq.{code}` (single) | GET | anon (public RLS) | `code` eq (default `'UMCCC'`) + `single` | `SupabaseDb.initPublic()` | Resolve `school_id` by school code without login |
| PR3 | `/rest/v1/profiles?select=id,role,school_id,created_at&order=created_at` | GET | admin (RLS: `school_admin`/`super_admin` of same school) | none (RLS-scoped) | `_AccountsPageState._load()` | List school accounts; emails from auth session (masked for others) |
| PR4 | `/rest/v1/profiles?select=role&id=eq.{myId}` (single) | GET | session | `id` eq + `single` | `_AccountsPageState._fetchMyRole()` | Read own role to gate admin UI |
| PR5 | `/rest/v1/profiles?id=eq.{id}` | PATCH | admin (RLS) | Body `{role: newRole}`; gated by `_canManage` + not-yourself + not-super_admin checks in UI | `_AccountsPageState._openRoleEditor` → `.update(...).eq('id')` | Change another user's role |
| PR6 | *(invite)* — `POST /auth/v1/otp` (see A2) | POST | anon key | `{email}` | `_invite()` | Sends magic link; role assigned manually later (no `pending_invites` table in-repo) |

---

## 2. Request Payload Schemas & Validation Rules

### Validation is client-side (Flutter form validators) — no server DTO schemas in-repo
| Endpoint | Validation (client) |
|----------|--------------------|
| A1 sign-in | Email form validator requires a valid `@` address; password non-empty |
| A2 invite | Email must contain `@` |
| A4 change password | New password matches confirm; length constrain in widget; form `validate()` gate |
| P2/P3 player save | Model-level defaults applied (`title`→`''`, `gender`→`male`, `member_status`→`member`, etc.); negative-number safety not enforced server-side in-repo |
| X4 tournament upsert | Enum names validated (`format`, `status`, `rating_type`); jsonb snapshots pre-shaped by model |

### PostgREST query parameters used
- `select=...` (column list projection)
- `{col}=eq.{value}` (equality filter)
- `{col}=in.({csv})` / Dart `inFilter` (set membership)
- `order={col}.asc` / multiple `order=round.asc,board.asc`
- `Accept: application/vnd.pgrst.object+json` (`.single()` — treated as error if 0 or >1 rows)
- `Prefer: resolution=merge-duplicates` (upsert semantics)

---

## 3. Underlying Service Function → Operations Summary

| Service function (file) | Endpoint(s) | Summary of operations |
|--------------------------|-------------|-----------------------|
| `SupabaseDb.init()` (`supabase_db.dart:28`) | PR1 | Resolve & cache `school_id` from `profiles` for the signed-in user; throws if missing |
| `SupabaseDb.initPublic()` (`:39`) | PR2 | Resolve `school_id` by school code (no auth); no-op if already cached |
| `SupabaseDb.reset()` (`:48`) | — | Clear cached `_schoolId` on sign-out |
| `SupabaseDb.loadPlayers()` (`:57`) | P1 | Fetch + map all school players |
| `SupabaseDb.savePlayers()` (`:91`) | P2 | Bulk upsert players |
| `SupabaseDb.savePlayer()` (`:121`) | P3 | Single upsert |
| `SupabaseDb.deletePlayer()` (`:124`) | P4 | Hard delete |
| `SupabaseDb.loadTeams()` / `saveTeams()` / `deleteTeam()` (`:132–164`) | T1/T2/T3 | Roster CRUD |
| `SupabaseDb.loadTournaments()` (`:168`) | X1+X2+X3 | 3-query multi-table read joined in Dart into `Tournament` objects (roster + rounds + jsonb) |
| `SupabaseDb.saveTournament()` (`:299`) | X4+X5+X6 | 3-step upsert (metadata → roster → matches) |
| `SupabaseDb.saveTournaments()` (`:357`) | X8 | Sequential per-tournament save |
| `SupabaseDb.deleteTournament()` (`:363`) | X7 | Hard delete; relies on server FK cascade |
| `PendingSyncService.queue/trySyncAll` (`pending_sync_service.dart`) | P3/X4–X6 (deferred) | Offline fallback: queues player+tournament JSON in `shared_preferences`; drains to Supabase on launch / "Sync Now"; removes on success, keeps on failure |
| `MigrationService.migrate()` (`migration_service.dart`) | P2/X4–X6 | Idempotent legacy→Supabase push (players in batches of 50, then each tournament) |
| `LocalDbBackup.restore()` (`local_db_backup.dart`) | P2/X4–X6 | Restore backup file into Supabase as upsert |

---

## 4. Response Formats

**Success:** PostgREST returns `200 OK` (SELECT/single) or `201 Created`
(upsert) with JSON bodies — rows for `select`, or an empty/echo array for
upserts (not deeply consumed; the app uses the *in-memory* model it built).

**Failure (unified across all endpoints):** the `supabase_flutter` client
throws `AuthException` (auth endpoints) or a generic `Exception` / PostgREST
error (data endpoints) with an HTTP status (400/401/403/404/5xx). The app
has **no global error boundary**; each call site handles failures locally:

| Context | On failure |
|---------|-----------|
| Data load (`MainScreen._loadAll`, `PublicScreen._load`) | `catch` → falls back to the `LocalDb` snapshot (offline mode banner + Retry) |
| New-player / new-tournament / finalize persist | `catch` → `PendingSyncService.queue(...)`, increments pending-sync count, offline banner |
| Routine player update | `catch` → dropped (best-effort; not queued) |
| Auth (`login`, `invite`, `change password`) | `catch` → error message rendered in-form |
| Accounts load / role change | `catch` → error text + Retry (load) or dialog error (role) |

No HTTP status codes are inspected directly in this repo — error semantics
come through exceptions.

---

## 5. Middleware Pipeline Sequence (per request)

Since middleware is server-side (Supabase), the effective pipeline for every
request is:

```
[Flutter] build request (Dart client adds headers: apikey, Authorization: Bearer JWT)
   → [Supabase] Auth/API gateway validates JWT + key
   → [Supabase] PostgREST routes to /rest/v1/{table}
   → [Supabase - Database Middleware] Row-Level Security (RLS) policy evaluation
        · SELECT: model_using / USING clause
        · INSERT/UPDATE/DELETE: WITH CHECK / USING clause
        · role-dependent (my_role()), school-scoped (my_school_id())
   → [Supabase] DB triggers (if any — see Phase 2 §0; only referenced, not in-repo)
   → response JSON / error → [Flutter] catch/fallback handling
```

Order of authorization gates (app-level, before any request):
1. **Route gating** — `_AuthGate`: logged-out → `PublicScreen` (read-only
   callbacks are no-ops), logged-in → `MainScreen` (full CRUD).
2. **UI-level role gating** — Accounts page hidden/limited unless
   `_canManage` (`school_admin`/`super_admin`); can't edit own role or
   `super_admin`; role editor disabled otherwise.
3. **School scoping** — every query includes `school_id = eq.{_sid}`.
4. **Server RLS** — final enforcement (authoritative).

---

## 6. Complete API Call Inventory (call-site map)

| Call | File:Line |
|------|-----------|
| `auth.signInWithPassword` | `login_screen.dart:39` |
| `SatupabaseDb.init` (PR1) | `login_screen.dart:44`, `supabase_db.dart:32` |
| `auth.signInWithOtp` (invite) | `accounts_page.dart:491` |
| `auth.signOut` | `main.dart:1124` |
| `auth.updateUser` (password) | `accounts_page.dart:722` |
| `auth.onAuthStateChange` / `currentSession` | `main.dart:118,121` |
| `.from('profiles')` select/update | `supabase_db.dart:32`, `accounts_page.dart:88,126,179` |
| `.from('schools')` select | `supabase_db.dart:42` |
| `.from('players')` select/upsert/delete | `supabase_db.dart:59,117,125` |
| `.from('teams')` select/upsert/delete | `supabase_db.dart:134,159,164` |
| `.from('tournaments')` / `tournament_players` / `matches` | `supabase_db.dart:174–365` |
| Offline queue / migration / backup restore | `pending_sync_service.dart`, `migration_service.dart`, `local_db_backup.dart` |

---

## 7. Migration / Phase-4 Action Items

1. **RLS policies** referenced in code but not present in-repo must be
   created/verified in Supabase (public `schools` read, public school-data
   read for anon, `admins read/update school profiles`, per-school isolation
   on `players`/`teams`/`tournaments`, `tournament_players`, `matches`).
2. **Invite flow** has no `pending_invites` table and no auto-profile
   creation trigger in-repo (role is assigned manually after first sign-in) —
   decide whether to add a trigger/table or accept the manual step.
3. **Client-side validation only** — no server schema validation or request
   DTO contracts exist in this repo; introduce them if the migration needs
   strict server-side enforcement.
4. **Upsert bulk limits** — `MigrationService` batches players by 50; keep
   Supabase request size limits in mind for `saveTournaments` (full jsonb).

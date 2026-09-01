# ORCHESTRATOR BUILD PROMPT — Chess Manager (Flutter + Supabase, Clean Rebuild)

**Read this entire document before writing any code. It is the single source
of truth. It was reverse-engineered from a working production app, so every
rule, formula, and edge case below is intentional — not a suggestion.**

Mission: rebuild **Chess Manager**, a chess-club tournament management app,
from scratch, on the **same stack** as the original, with **100% feature
parity**. Nothing in the checklist in §4 may be skipped, simplified, or
"improved away." If something looks redundant or odd, implement it exactly
as specified anyway — these are documented, deliberate behaviors, not bugs.

Treat this file as the spec for a multi-agent build. §9 proposes how to
split work across sub-agents/tasks. Before declaring the build done, every
box in §4 must be verifiably checked against the running app.

---

## 0. Ground Rules

1. **Stack is fixed** — do not swap any of these for alternatives:
   - Language/framework: **Dart** (SDK `>=3.0.0 <4.0.0`), **Flutter**, Material 3, **dark theme**.
   - Backend: **Supabase** (Postgres via PostgREST + GoTrue auth). No ORM — raw table builders/upserts only, exactly like the original.
   - Local persistence: **`shared_preferences`** (offline cache + sync queue).
   - File storage: **`path_provider`** (documents dir for JSON backup files) — no cloud storage.
   - Lint/test: `flutter_lints`, `flutter_test`.
   - Config: **compile-time only** via `--dart-define-from-file=.env` (no runtime `.env` loading).
   - Deploy target: static web build (Netlify-style SPA redirect), plus native targets (Android/iOS/Windows/macOS/Linux) via standard Flutter scaffolding.
2. **No new third-party integrations.** No payment/billing, no email provider, no analytics/crash reporting, no push notifications, no cloud storage buckets, no Supabase Edge Functions/RPC/Realtime/webhooks, unless a later spec explicitly adds them. This is a deliberate constraint of the original app — preserve it.
3. **Single state-owner architecture.** One top-level stateful widget owns the in-memory `players` / `tournaments` / `teams` lists and is the **only** caller of the Supabase service layer. All page widgets are presentational: they receive data + callbacks as props; mutations flow back up to the owner. Do not let individual pages talk to Supabase directly.
4. **Algorithms are correctness-critical.** The Elo/rating math, pairing engines, standings/tiebreak order, and rounding rules must match §5 exactly, including the specific quirks (e.g., two different rounding strategies coexisting on purpose — see §5.1). Do not "clean up" or unify them.
5. **No server-side schema files exist in the source app** — the schema was reverse-engineered from client code. §2 gives you the reconstructed DDL to actually create in Supabase for this rebuild (this is new — the original never had it in-repo).
6. Ship with the same three-way test suite the original had (§8), covering individual pairing, team pairing, and offline sync.
7. **The codebase itself must be clean, not just feature-complete.** See §10 for concrete
   structure/naming/size rules. A build that passes every checkbox in §4 but is organized as a
   handful of 2,000-line files is not acceptable — the QA pass in §9 checks §10 too.

---

## 1. Architecture Overview

```
lib/
  main.dart                     # Entry point, auth gate, single state owner
                                 #   (_MainScreenState), Dashboard
  demo_data.dart                # Sample dataset, seeded when --dart-define=SEED_DEMO=true
  models/
    player.dart                 # Player model + enums + JSON (+ legacy decode fallbacks)
    team.dart                   # Team / TeamRoundPairing / RosterTeam models + JSON
    tournament.dart             # Tournament, ChessMatch, standings, tiebreaks,
                                 #   BracketGenerator (all pairing engines)
  pages/
    login_screen.dart           # Email/password auth
    accounts_page.dart          # Admin-only account management (invites, roles, password)
    players_page.dart           # Roster CRUD (list, search, sort, add/edit/delete)
    player_profile_page.dart    # Individual player detail / history / edit
    teams_page.dart             # Saved reusable team rosters CRUD
    tournaments_page.dart       # Tournament list, creation, mutation, setup dialog
    f2f_tournament_view.dart    # In-person tournament detail UI (pairings, entry, standings)
    online_tournament_view.dart # Import/enter externally-run tournaments (scoreboard style)
  services/
    supabase_db.dart            # Supabase read/write layer (source of truth online)
    local_db.dart                # shared_preferences snapshot cache (offline read fallback)
    local_db_backup.dart        # JSON backup/restore + BackupManagerDialog
    pending_sync_service.dart   # Offline write queue (players/tournaments) + Sync Now
    rating_service.dart         # FIDE Elo (expected score, K-factor, apply)
    migration_service.dart      # One-time local-storage → Supabase migration
  widgets/
    player_picker_widget.dart   # Reusable searchable/sortable player selector
test/
  pairing_test.dart             # Individual Swiss pairing engine regression tests
  team_pairing_test.dart        # Team Swiss pairing + standings tests
  pending_sync_test.dart        # Offline sync queue tests
```

**Data flow (must match exactly):**

```
User input (pages/dialogs)
  → client-side form validation (email contains "@", password ≥ 8 chars, non-empty names…)
  → page calls state-owner callback (onCreate / onUpdate / onUpdatePlayer …)
  → _MainScreenState mutates in-memory lists (indexWhere + replace, never blind addAll on top
    of existing state — clear-then-addAll on reload to avoid duplicate rows on re-login)
  → persistence layer: try SupabaseDb.save*() → on failure, PendingSyncService.queue() (lossless)
  → Supabase (PostgREST/GoTrue) or local shared_preferences / backup files
  → reads flow back through loadPlayers/loadTournaments/loadTeams → snapshot to LocalDb → render
```

There is no server middleware and no client-side HTTP interceptor. Failures are caught per call
site and converted to either a `bool` return, an offline-queue enqueue, or a local-snapshot
fallback — **never** an unhandled crash.

---

## 2. Database Schema (create this in Supabase — reconstruct exactly)

8 database objects: 7 tables + Supabase's managed `auth.users`. Every tenant-scoped table is
filtered by `school_id` in the app AND must be enforced by RLS server-side.

```sql
-- schools: lookup table for public-access school-code resolution
create table schools (
  id   uuid primary key default gen_random_uuid(),
  code text not null unique               -- e.g. 'UMCCC'; looked up via .eq('code', code).single()
);

-- profiles: auth.users -> school_id/role mapping
create table profiles (
  id         uuid primary key references auth.users(id),
  role       text not null default 'player' check (role in ('player','school_admin','super_admin')),
  school_id  uuid references schools(id),
  created_at timestamptz not null default now()
);

-- players: roster, scoped by school
create table players (
  id            text primary key,          -- app-generated sequential 6-digit string, >=100000
  school_id     uuid not null references schools(id),
  first_name    text not null,
  last_name     text not null,
  blitz_rating  int  not null default 1500,
  rapid_rating  int  not null default 1500,
  email         text,
  phone         text,
  title         text not null default '',  -- '' | GM | IM | FM | CM | NM
  gender        text not null default 'male' check (gender in ('male','female','other')),
  member_status text not null default 'member' check (member_status in ('member','guest')),
  college       text not null default '',  -- college (members) / school (guests)
  program       text not null default '',  -- course/degree or grade
  wins          int  not null default 0,
  losses        int  not null default 0,
  draws         int  not null default 0,
  is_active     boolean not null default true,   -- SOFT DELETE flag (only mechanism for players)
  created_at    timestamptz not null default now()
);
create index on players (school_id);
create index on players (last_name);

-- teams: reusable saved rosters, independent of tournaments, capped ~10 players in the UI
create table teams (
  id         text primary key,             -- app-generated
  school_id  uuid not null references schools(id),
  name       text not null,
  player_ids jsonb not null default '[]'   -- ordered array of player id strings = board order; NOT FK-enforced
);
create index on teams (school_id);

-- tournaments: metadata + jsonb snapshots
create table tournaments (
  id               text primary key,       -- ms-epoch string
  school_id        uuid not null references schools(id),
  name             text not null,
  format           text not null default 'swiss' check (format in ('roundRobin','knockout','swiss')),
  status           text not null default 'draft' check (status in ('draft','inProgress','completed')),
  rating_type      text not null default 'rapid' check (rating_type in ('blitz','rapid')),
  is_rated         boolean not null default true,
  current_round    int not null default 0,
  max_boards       int,                    -- non-null iff a team tournament
  rating_snapshot  jsonb not null default '{}',  -- playerId -> pre-finalization rating (undo)
  wdl_snapshot     jsonb not null default '{}',  -- playerId -> {wins,draws,losses} (undo)
  tiebreak_results jsonb not null default '{}',  -- "winnerId_loserId" -> winnerId
  teams            jsonb not null default '[]',  -- Team[] snapshot, present iff team tournament
  team_pairings    jsonb not null default '[]',  -- TeamRoundPairing[][] parallel to rounds
  created_at       timestamptz not null default now()
);
create index on tournaments (school_id);

-- tournament_players: roster snapshot (rating AT ENROLLMENT TIME)
create table tournament_players (
  tournament_id text not null references tournaments(id) on delete cascade,
  player_id     text not null references players(id),
  blitz_rating  int not null,
  rapid_rating  int not null,
  primary key (tournament_id, player_id)
);
create index on tournament_players (tournament_id);

-- matches: one row per ChessMatch
create table matches (
  id                 text primary key,     -- e.g. 'rr_0_0', 'sw_1_0', 'ko_1_1', 'tsw_...'
  tournament_id      text not null references tournaments(id) on delete cascade,
  round              int not null,
  board              int not null,
  white_player_id    text references players(id),   -- null = bye
  black_player_id    text references players(id),   -- null = bye
  result             text not null default 'pending'
                       check (result in ('pending','whiteWins','blackWins','draw','bye')),
  white_rating_delta int,                  -- null until finalize or backfill
  black_rating_delta int
);
create index on matches (tournament_id, round, board);
```

**RLS policies to create (authorization boundary lives here, not in the app):**
- Public (anon) `select` on `schools` — for `initPublic(schoolCode)` resolution.
- Public (anon) `select` on `players` / `tournaments` / `teams` scoped by `school_id`, for the
  read-only `PublicScreen`.
- Authenticated `select`/`insert`/`update`/`delete` on `players` / `teams` / `tournaments` /
  `tournament_players` / `matches`, scoped to the caller's `school_id` (via a `my_school_id()`
  helper reading `profiles`).
- `profiles`: `admins read school profiles` — select where `school_id = my_school_id()` and
  `my_role() in ('school_admin','super_admin')`.
- `profiles`: `admins update school profiles` — same predicate, for `update`.
- A user can always read their own `profiles` row.
- **No trigger exists in the original repo to auto-create a `profiles` row on signup.** Either
  add one now (recommended: on `auth.users` insert, create a `profiles` row with
  `role='player'`, `school_id=null`) or explicitly preserve the manual-role-assignment gap and
  document it — but decide one way, don't leave it ambiguous.

**Constraints to double check:** `ON DELETE CASCADE` from `tournaments` → `tournament_players`
and `matches` (the app relies on this — `deleteTournament` only deletes the `tournaments` row
and expects the DB to cascade). `schools.code` must be unique (`.single()` lookup assumes it).

---

## 3. Environment Variables & Config Constants

All configuration is **compile-time**, via `--dart-define-from-file=.env`. No runtime env
loading.

| Variable | Type | Required | Behavior |
|---|---|---|---|
| `SUPABASE_URL` | String | yes | `main()` throws `StateError` if empty |
| `SUPABASE_ANON_KEY` | String | yes | publishable/anon key; safe client-side; `main()` throws if empty |
| `SEED_DEMO` | bool | no (default `false`) | if `true`, seeds `LocalDb` with `DemoData` — touches only the local snapshot, never live Supabase data |

Hard-coded config constants to preserve exactly:
- `initPublic({schoolCode = 'UMCCC'})` — default public school code.
- Swiss/team-Swiss backtracking attempt cap: **`maxAttempts = 20000`**.
- Migration batch size: **50** players per upsert batch.
- `shared_preferences` keys: `chess_players_v1`, `chess_tournaments_v1`, `chess_teams_v1`,
  `pending_tournament_finalizations_v1`.
- Backup file prefix: `chess_backup_`; backup schema `version: 1`.
- `.env` must stay git-ignored.

---

## 4. Exhaustive Feature Checklist

Every item below must exist and behave as described. Use this as the acceptance checklist —
literally check items off as you verify them against the running build.

### 4.1 Auth & access
- [ ] Email/password login (`signInWithPassword`); on success, resolve `school_id` via
      `SupabaseDb.init()`.
- [ ] Admin "invite user" flow via magic link (`signInWithOtp`), **not** `signInWithPassword` —
      role assigned manually post-signup (no auto-create trigger unless you added one in §2).
- [ ] Change password (`updateUser`), 8-char minimum, confirm-match validation.
- [ ] **Offline-safe session gate**: login state (`_loggedIn`) is derived purely from the
      *locally persisted* Supabase session — it must NOT depend on a network call. This lets a
      previously-authenticated user open the app fully offline instead of being bounced to the
      public view.
- [ ] Roles: `player` (default), `school_admin`, `super_admin`, stored in `profiles.role`.
- [ ] Sign out clears the cached `school_id` in the service layer (`SupabaseDb.reset()`).
- [ ] **PublicScreen** (unauthenticated, read-only): Players/Teams/Tournaments views for a
      school resolved by the hard-coded default code `'UMCCC'`; falls back to the local
      snapshot when offline; shows an offline banner; **zero write capability**.
- [ ] **MainScreen** (authenticated): full CRUD, only reachable when logged in.

### 4.2 Player roster management
- [ ] Create/edit/delete players with fields: first name, last name, blitz rating, rapid
      rating, email (nullable), phone (nullable), FIDE title (`''`/GM/IM/FM/CM/NM), gender
      (male/female/other), member status (member/guest), college/school, program/grade, active
      flag.
- [ ] Auto-assigned sequential 6-digit player IDs (`Player.nextId`): max numeric existing ID + 1,
      floor 100000.
- [ ] Search by name, case-insensitive, `trim().toLowerCase()` contains-match.
- [ ] Filter by active / guest / name / title / school.
- [ ] Sort options on the roster page.
- [ ] **Soft delete only** via `is_active` toggle — inactive players are hidden from pickers but
      retained (history intact). No `deleted_at`.
- [ ] Hard delete still exists as a distinct destructive action (`deletePlayer`).
- [ ] Player profile page: full detail, cumulative career stats (wins/draws/losses, win rate,
      games played), tournament history, guest badge, active/inactive toggle, edit, delete.
- [ ] Derived metrics: `gamesPlayed = wins+draws+losses`; `score = wins + draws*0.5`;
      `winRate = gamesPlayed==0 ? 0 : wins/gamesPlayed` (divide-by-zero guarded).

### 4.3 Team roster management (reusable, tournament-independent)
- [ ] `RosterTeam`: build a named roster once, reuse across many team tournaments.
- [ ] Board order matters — `player_ids` is an **ordered** list.
- [ ] Cap of ~10 players per saved roster.
- [ ] CRUD + search (`trim().toLowerCase()` contains-match) on the Teams page.

### 4.4 Tournament management — general
- [ ] Create tournament: name, format (Round Robin / Knockout / Swiss), rated vs unrated,
      rating type (blitz/rapid), rounds (auto per format, or manual override for Swiss).
- [ ] Roster selection: add/remove players from the tournament.
- [ ] **Latecomer support**: join a player into an in-progress Swiss tournament; they start
      with a **0.5-point handicap**, detected by first-appearance round in standings, no matter
      which round they actually join.
- [ ] Generate next round per the active format's engine.
- [ ] Manual board-color override: a per-pairing white/black toggle UI, independent of the
      engine's auto-assignment.
- [ ] Record match results: white wins / black wins / draw / (auto) bye.
- [ ] Tiebreaker entry: manual head-to-head result injection
      (`tiebreakResults["winnerId_loserId"] = winnerId`), consumed by standings' direct-encounter
      tiebreak. Malformed keys are skipped, not fatal.
- [ ] `f2f_tournament_view.dart` style board-by-board play surface with per-match result entry.
- [ ] `online_tournament_view.dart` style scoreboard for entering results of an externally-run
      (already-completed elsewhere) tournament, then applying rating changes.

### 4.5 Tournament formats & pairing engines (see §5.2 for exact algorithms)
- [ ] **Round Robin** — Berger circle rotation, alternating colors, dummy bye player for odd
      fields.
- [ ] **Knockout** — single elimination, power-of-2 bracket seeding with byes interleaved by
      bracket position (never trailing), one round generated at a time from winners.
- [ ] **Swiss** — global backtracking pairing engine: score-group ordering, staged constraint
      relaxation (rematch/color-clash), fair bye rotation, local color-clash repair pass,
      20,000-attempt cap with rescue pairing for leftovers, auto-stop when `allPairsPlayed`.
- [ ] **Team tournaments**: fixed board count (`maxBoards`), `boardSlots` per team (nullable
      slots for short rosters), Olympiad-style board color alternation, forfeited boards counted
      as individual byes, separate team-Swiss engine mirroring the individual one at team
      granularity, `TeamRoundPairing` records persisted per round (needed because a forfeited
      board has a null player and the absent team can't be inferred from match data alone).

### 4.6 Ratings (FIDE Elo)
- [ ] `expectedScore(ra, rb) = 1 / (1 + 10^((rb-ra)/400))`.
- [ ] `actualScore`: whiteWins→(1,0), blackWins→(0,1), draw→(0.5,0.5), pending→0 (byes filtered
      by caller before this is reached).
- [ ] Tiered K-factor: `gamesPlayed < 30` → 40; else `rating < 2400` → 20; else → 10.
- [ ] Two separate, independently-tracked rating pools: **blitz** and **rapid**.
- [ ] Per-game rating deltas written onto each match (`whiteRatingDelta`/`blackRatingDelta`),
      **rounded per game** — this is the authoritative source of truth for applying a player's
      total change (see §5.1 for why this must coexist with a second, differently-rounded
      calculation used elsewhere).
- [ ] Rating snapshots (`ratingSnapshot`) taken pre-finalization to support undo.

### 4.7 Standings & tiebreaks
- [ ] Individual standings compute: points, wins/draws/losses, progressive (cumulative) score,
      Buchholz, Buchholz Cut-1, Sonneborn-Berger, direct encounter (including injected
      tiebreaker results), plus wins and rating as final fallback tiebreaks.
- [ ] Exact sort order: **points → Buchholz-Cut1 → Buchholz → Progressive → Direct Encounter →
      Sonneborn-Berger → Wins → Rating** — all descending, each level only breaking ties from
      the previous.
- [ ] A bye counts as **+1 point and a win** in standings.
- [ ] Late joiners seed at **0.5 points** (both raw points and the progressive running total).
- [ ] Team standings: match points, board points, team Buchholz (sum of opponents' final match
      points); sort by matchPoints → boardPoints → buchholz → team name. Team standings
      deliberately **omit** progressive score and Sonneborn-Berger (documented simplification).

### 4.8 Tournament finalization / undo
- [ ] "End Tournament" (rated path): snapshot pre-tournament ratings + W/D/L, compute per-match
      Elo deltas with **fixed initial ratings for the whole tournament** (no compounding round to
      round), apply deltas + W/D/L to the master roster, mark `completed`.
- [ ] "End Tournament" (unrated path): still snapshots W/D/L for undo support; applies only
      W/D/L, no rating change.
- [ ] **Undo last submission**: available only for tournaments with a non-empty `wdlSnapshot`;
      restores ratings (if rated) and W/D/L from the snapshots, reopens to `inProgress`, clears
      the snapshots and all per-match deltas.
- [ ] **Reopen legacy tournament**: for tournaments completed before snapshot tracking existed
      (empty `wdlSnapshot`) — sets status back to `inProgress` **without** rolling back any
      rating/W-D-L change, and the UI must explicitly warn the user that the original
      contribution stays "baked in" before they proceed.

### 4.9 Dashboard & maintenance
- [ ] Dashboard stat cards: member count, guest count, average rating (blitz/rapid toggle,
      integer-floor division, zero-guarded), tournament count, active (in-progress) tournament
      count, top-5 players by rating, recent tournaments list, status chips.
- [ ] **Recalculate W/D/L from history**: idempotent — resets every player's W/D/L to zero, then
      replays every `completed` tournament's matches. Byes are **excluded** here (unlike
      standings, where a bye counts as a win) — this is intentional, not a bug.
- [ ] **Backfill per-match rating deltas**: fills in `whiteRatingDelta`/`blackRatingDelta` for
      rated, completed tournaments that predate per-match tracking, reconstructing
      pre-tournament ratings from `ratingSnapshot`. Skips tournaments with no snapshot to
      reconstruct from. Display-only — never touches current player ratings. Report counts:
      filled / skippedNoSnapshot / alreadyDone / notRated.

### 4.10 Offline resilience
- [ ] Offline **write** queue (`PendingSyncService`), backed by `shared_preferences`: new
      players, new/updated tournaments, and finalizations are queued on any Supabase write
      failure. Queuing a tournament stores its **full roster** so it's reconstructable from a
      single queue entry. Re-queuing the same tournament id **replaces** the earlier entry (no
      duplicate growth).
- [ ] Drain triggers: on every authenticated launch, and via a manual **"Sync Now"** button.
      Failed entries stay queued for the next attempt; no exponential backoff — this is a
      deliberate, simple, user-triggered retry model.
- [ ] Offline **read** fallback: every successful load snapshots to `LocalDb`
      (fire-and-forget). If Supabase is unreachable, the last snapshot renders instead of an
      empty screen, with an offline banner + retry.
- [ ] Routine player-profile edits are best-effort — saved directly, **not** queued, so they can
      be silently dropped if offline (this asymmetry vs. tournament/player-creation writes is
      intentional).

### 4.11 Backup, restore, migration
- [ ] **Backup**: export current roster + tournaments to a timestamped JSON file
      (`version: 1`) in the platform documents directory, filename
      `chess_backup_<ISO8601-with-":"-and-"."-replaced-by-"-">.json`.
- [ ] **List backups**: scan the documents dir for filenames containing `chess_backup_`; treat
      any matching file as a backup candidate (documented filename-prefix contract, not a strict
      format check); return empty list if the directory doesn't exist yet (no crash).
- [ ] **Restore**: reject with a clear error if `version != 1`; otherwise **upsert only** — adds
      or updates by id, **never deletes** anything not present in the backup file.
- [ ] **Delete backup** file action.
- [ ] **One-time legacy→Supabase migration** (`MigrationService.migrate`): idempotent; players
      pushed in batches of 50; then each tournament (metadata → roster → matches); collects
      per-item errors without aborting the whole run; reports progress via a callback and total
      elapsed time; players always migrated before tournaments (tournaments reference player
      ids).

### 4.12 Admin / accounts page
- [ ] List all accounts for the current school (admin-only: `school_admin`/`super_admin`).
- [ ] Change another user's role — but **cannot** edit your own role, and **cannot** edit a
      `super_admin`'s role.
- [ ] Send invites via magic link; role is assigned manually after first sign-in (no automatic
      profile-row creation unless you built the trigger in §2 — either way, be consistent and
      don't leave the invited user stuck unable to reach `MainScreen`).
- [ ] Emails for other users are masked in the UI; only the current user's own email is shown
      in full (read from the auth session, not queried from a table).

### 4.13 Explicit non-features (do not add)
- [ ] No payment/billing logic anywhere.
- [ ] No email/SMS provider integration (auth emails are sent by Supabase's managed Auth
      service only).
- [ ] No analytics or crash reporting SDK.
- [ ] No cloud object storage — backups are local-filesystem only via `path_provider`.
- [ ] No Supabase Edge Functions, RPC calls, Realtime subscriptions, or webhooks (inbound or
      outbound).
- [ ] No cron jobs / scheduled tasks / background isolates / `Timer.periodic`. All "background"
      work is triggered synchronously by a user action or app launch, in the UI isolate.
- [ ] No automatic retry with exponential backoff anywhere — retries are manual/user-triggered
      only (see §4.10).

---

## 5. Algorithms (implement exactly as specified)

### 5.1 Ratings — `RatingService`

```
FUNCTION expectedScore(ra, rb):
    RETURN 1 / (1 + 10 ^ ((rb - ra) / 400))

FUNCTION actualScore(result, isWhite):
    whiteWins -> isWhite ? 1.0 : 0.0
    blackWins -> isWhite ? 0.0 : 1.0
    draw      -> 0.5
    default (pending) -> 0.0
    // bye is filtered out by callers BEFORE this is reached

FUNCTION kFactor(player, ratingType):
    rating = (ratingType == blitz) ? player.blitzRating : player.rapidRating
    IF player.gamesPlayed < 30: RETURN 40
    IF rating < 2400:           RETURN 20
    RETURN 10

FUNCTION totalRounds(format, n):
    roundRobin: n is odd ? n : n - 1
    knockout:   size = smallest power of 2 >= n; rounds = bitLength(size) - 1
    swiss:      n<=4 -> 3; n<=8 -> 4; n<=16 -> 5; else -> 7   (or explicit user override)
```

**⚠️ Two coexisting, differently-rounded rating calculations — keep both, do not unify:**

```
// (A) Whole-tournament change map — secondary/legacy path
FUNCTION calculateTournamentChanges(players, rounds, ratingType):
    initialRatings = fixed snapshot of each player's rating at call time
    changes[id] = 0.0 for all
    FOR each round, each match (skip pending & byes):
        use INITIAL ratings (never in-progress values) for both expected-score calcs
        changes[white] += Kw * (Sw - Ew)
        changes[black] += Kb * (Sb - Eb)
    RETURN each changes[id].round()     // ONE rounding, at the very end, per player

// (B) Per-match deltas — PRIMARY / authoritative path, used at finalization
FUNCTION calculateAndApplyMatchDeltas(players, rounds, ratingType):   // mutates matches in place
    initialRatings = fixed snapshot, same as above
    totals[id] = 0 (int) for all
    FOR each round, each match (skip pending & byes):
        whiteDelta = round(Kw * (Sw - Ew))     // rounded PER GAME
        blackDelta = round(Kb * (Sb - Eb))
        match.whiteRatingDelta = whiteDelta    // WRITE onto the match record
        match.blackRatingDelta = blackDelta
        totals[white] += whiteDelta; totals[black] += blackDelta
    RETURN totals   // this IS the number applied to the player's overall rating

FUNCTION applyChanges(players, changes, ratingType):
    FOR each player: rating[ratingType] += changes[player.id] ?? 0   // other pool untouched
```

> Because (B) rounds every game individually, the sum can differ by ±1–2 from (A)'s single
> end-of-tournament rounding. **Finalization always uses (B)'s `totals` as authoritative**, so
> the visible per-game numbers always sum exactly to the applied total. Preserve this exact
> divergence — it is a documented, load-bearing quirk, not something to "fix."

### 5.2 Pairing engines — `BracketGenerator`

**Round Robin (Berger circle rotation):**
```
IF n is odd: append a dummy bye-player (id 'bye', 0 ratings)
FOR r in 0..n-2:
    pairs = (ps[i], ps[n-1-i]) for i in 0..n/2-1
    either side is the bye-player -> ChessMatch(white=real player, black=null, result=bye)
    else -> assign colors via _assignColors; id 'rr_{r}_{i}', round r+1, board i+1
    Berger rotation: move ps[last] to index 1 (everyone else shifts)
```

**Knockout (single elimination), seeded bracket:**
```
FUNCTION _bracketSeedOrder(size):        // recursive classic seeding
    size==1 -> [1]
    prev = _bracketSeedOrder(size/2)
    RETURN flatten([s, size+1-s] for s in prev)     // size=8 -> [1,8,4,5,2,7,3,6]

seeded = sort players by rating desc, map via seed order; seed# > player count -> null (bye)
Round 1: pair consecutive seeded[i], seeded[i+1]; if both real, the more white-heavy player
         (_colorBalance) becomes black; a null slot -> bye match.
Next rounds: pair winners consecutively (odd leftover -> bye); colors via _assignColors against
         full history. Only round 1 is generated up front; later rounds generate one at a time
         from that round's winners.
```

**Swiss round 1:**
```
sort players by rating desc; half = n/2
pair sorted[i] (white) vs sorted[i+half] (black) for i in 0..half-1
if n is odd: sorted.last gets a bye
```

**Swiss subsequent rounds — the most complex algorithm in the app:**
```
1. Group players by current score (points), groups ordered desc; within a group, preserve the
   full standings tiebreak order (Buchholz-Cut1 -> Buchholz -> Progressive -> SB -> Wins -> Rating).
2. If odd count: bye assigned to the LOWEST-ranked player who has NOT yet had a bye this
   tournament; if everyone has had one, repeat a bye as the last resort. Remove from the
   pairing pool.
3. pairs = _matchAll(pairablePlayers, previousRounds)
4. pairs = _repairColorClashes(pairs, previousRounds)
5. Assign colors per pair via _assignColors; sequential board numbers.
6. Any players still unpaired after the attempt cap are force-paired in a rescue pass — never
   silently dropped from the round.
7. Append the bye match last.

FUNCTION _matchAll(order, previousRounds):
    // staged constraint relaxation: try hardest constraints first, relax in this exact order
    FOR excludeRematch in [true, false]:
      FOR excludeClash in [true, false]:
        result = _maxMatch(order, previousRounds, excludeRematch, excludeClash)
        IF result.unpaired is empty: RETURN result immediately (perfect match found)
        keep the attempt with the FEWEST unpaired players as "best so far"
    RETURN best
    // i.e.: (no rematch, no clash) -> (rematch ok, no clash) -> (no rematch, clash ok) ->
    //       (rematch ok, clash ok). Rematches are relaxed BEFORE color clashes.

FUNCTION _maxMatch(order, previousRounds, excludeRematch, excludeClash):
    // backtracking search for maximum-cardinality matching, capped at 20,000 attempts
    bestUnpairedCount = infinity; attempts = 0; stop = false
    SEARCH(idx, currentPairs, usedSet, unpairedSoFar):
        IF stop: return
        attempts += 1; IF attempts > 20000: stop = true; return
        i = next unused index >= idx
        IF i is past the end:                       // a complete candidate assignment
            IF unpairedSoFar.length < bestUnpairedCount:
                record as new best; IF unpairedSoFar.length == 0: stop = true
            return
        IF unpairedSoFar.length >= bestUnpairedCount: return    // can't beat current best, prune
        p1 = order[i]
        candidates = unused players after i
        IF excludeRematch: drop any candidate p1 has already played
        IF excludeClash:   drop any candidate that would force a same-color clash with p1
        sort candidates: prefer no-rematch, then no-clash, then closeness to p1's original rank
        FOR each candidate: tentatively pair (p1, candidate); recurse; backtrack; stop early if `stop`
        // fallback branch: also try leaving p1 unpaired this round, then recurse on i+1
    RETURN best found (or: nothing pairs, everyone unpaired, as a last-resort fallback)

FUNCTION _assignColors(a, b, rounds):
    streak(x) = +N for N consecutive whites, -N for N consecutive blacks, reading the player's
                games backwards from the most recent round, skipping byes, stopping at the first
                color change.
    aMustBlack = streakA >= 2;  aMustWhite = streakA <= -2   (same for b)
    // "must" = has played 2+ of the same color in a row -> the OTHER color is mandatory now
    both locked, compatible (one mustWhite, other mustBlack) -> honor both directly
    both locked to the SAME color (unavoidable clash)        -> (rounds.length + a.id.hash) even? tiebreak
    only one side locked                                      -> honor it
    neither locked (soft rule): more black-heavy streak is "more due" for white; ties broken by
       overall color balance (whites - blacks, lower = more due for white); final tie ->
       (rounds.length + a.id.hash) even? tiebreak
    // The parity tiebreak intentionally FLIPS round to round so the same side of a pairing
    // isn't systematically favored.

FUNCTION _repairColorClashes(pairs, previousRounds):
    FOR each pair that forces a color clash:
        try swapping opponents with another pair (two possible cross-swaps) such that NEITHER
        resulting pairing creates a rematch or a new clash; take the first swap that works;
        if no swap resolves it, leave the pair as-is (an unavoidable rare clash — _assignColors
        still picks a fair color).

FUNCTION allPairsPlayed(players, previousRounds):
    true iff EVERY unordered pair of players has already faced each other -> stop offering new
    Swiss rounds (a further round would be a forced rematch), except an explicit tiebreaker flow.
```

**Team Swiss — a deliberately separate implementation mirroring the individual engine at team
granularity** (do not merge it into the individual engine — this separation is intentional so
the hardened individual code path is never touched by team-specific changes):
```
Round 1: sort teams by average rating of their non-null board-slot players desc (0 if none
         rated); top half vs bottom half, top-half team plays white; odd team count -> last
         team gets a full-match-point bye (every present player on that team gets an individual
         bye too, feeding individual standings/W-D-L identically to a normal Swiss bye).

Subsequent rounds: group teams by matchPoints desc; same staged backtracking
         (_matchAllTeams/_maxMatchTeams, same 20,000 cap) and _repairTeamColorClashes;
         _assignWhiteTeam mirrors _assignColors using team-level streak/balance
         (_teamWhiteStreak / _teamColorBalance); allTeamPairsPlayed mirrors allPairsPlayed.

Board construction (_buildTeamPairingMatches), Olympiad-style alternation:
    FOR board i in 0..maxBoards-1:
        wPlayer = whiteTeam.boardSlots[i]; bPlayer = blackTeam.boardSlots[i]  (may be null)
        both null            -> no match generated for this board
        exactly one present  -> that player gets an individual bye (forfeited board)
        both present         -> ODD boards: whiteTeam's player is White
                                 EVEN boards: FLIPPED — blackTeam's player is White
                                 (so each physical team mixes colors within a single round)
```

### 5.3 Standings & tiebreaks — `Tournament.standings`

```
Late-joiner detection: a player's EARLIEST appearance (playing OR a bye) across all rounds.
   If that first round is 2+, they are a late joiner -> seed both raw points AND the running
   progressive total at 0.5. Players who never appear in any match at all are left at 0 (NOT
   treated as late joiners).

Pass 1 (basic tally), per real match, skipping pending:
   bye -> present player: +1 point, +1 win, no draw/loss, no opponent recorded
   decisive/draw -> update points/wins/draws/losses for both sides from the result

Pass 2 (progressive): running cumulative score updated after each round; late joiners' running
   total starts at 0.5 instead of 0.

Pass 3 (opponent-based tiebreaks), per player:
   opponentScores = final points of every opponent faced
   buchholz     = sum(opponentScores); empty -> 0
   buchholzCut1 = buchholz - min(opponentScores)   // drop the single lowest opponent score
   sonnebornBerger = sum over games: win -> opponent's final points; draw -> half of that;
                     loss -> 0
   directEncounter[a][b] = total points a scored specifically against b across all rounds,
     PLUS any manually-entered tiebreakResults ("winnerId_loserId" -> winnerId) injected as a
     full 1.0-point win for the winner against the loser.

Final sort (each level only breaks ties left by the previous one):
   1. points (desc)
   2. Buchholz-Cut1 (desc)
   3. Buchholz (desc)
   4. Progressive (desc)
   5. Direct Encounter — more points head-to-head wins (desc)
   6. Sonneborn-Berger (desc)
   7. Wins (desc)
   8. Rating (desc)
```

**Team standings** — `Tournament.teamStandings` (deliberately omits progressive score and
Sonneborn-Berger as a club-scale simplification):
```
boardPointsFor(team, roundMatches) = sum over that team's roster players in the round:
   white win or white-side bye -> +1; white draw -> +0.5
   black win                   -> +1; black draw -> +0.5

FOR each recorded TeamRoundPairing per round:
   bye (no opponent team) -> +1 match point, +1 match win, +1 match played, board points untouched
   else: compute boardPointsFor both teams; award board points to each;
         higher board points -> +1 match point / win for that team, loss for the other
         equal board points  -> +0.5 match point each, draw for both

Team Buchholz = sum of each faced opponent's FINAL match points (computed after all rounds).
Sort: matchPoints desc -> boardPoints desc -> teamBuchholz desc -> team name asc.
```

### 5.4 Finalization / undo state machine

States: `draft -> inProgress -> completed`, with an explicit reopen path back to `inProgress`.

```
FUNCTION endTournament(t):
    standings = compute t.standings (source of W/D/L deltas to apply)
    IF NOT t.isRated:
        t.wdlSnapshot = current master W/D/L for every player in t.players   // for undo
        t.status = completed
        for each roster player: apply ONLY W/D/L deltas from standings onto the CURRENT
                                 master player record (not the roster snapshot)
    ELSE:
        t.ratingSnapshot = current master rating (blitz or rapid, per t.ratingType) per player
        t.wdlSnapshot    = current master W/D/L per player
        changes = calculateAndApplyMatchDeltas(t.players, t.rounds, t.ratingType)   // §5.1(B)
        for each roster player: apply rating delta (only the matching pool) + W/D/L deltas
                                 onto the CURRENT master player record
        t.status = completed
    persist via the normal finalize path; on failure, queue offline with the FULL roster (§4.10)

FUNCTION undoLastSubmission(t):
    // t = the most recent COMPLETED tournament with a NON-EMPTY wdlSnapshot (works for both
    // rated and unrated tournaments)
    for each roster player:
        restored = current master player
        IF t.isRated AND ratingSnapshot[id] exists: restore that rating pool from the snapshot
        IF wdlSnapshot[id] exists: restore wins/draws/losses from the snapshot
    t.players = restored; t.status = inProgress
    clear t.ratingSnapshot and t.wdlSnapshot
    clear whiteRatingDelta/blackRatingDelta on every match in t.rounds
    persist tournament + each restored player

FUNCTION reopenLegacy(t):
    // t = most recent completed tournament, but its wdlSnapshot is EMPTY (predates snapshot
    // tracking — its pre-tournament state is unrecoverable)
    t.status = inProgress   // that's it — no rollback of ratings or W/D/L
    // UI MUST show an explicit warning before this action: re-ending the tournament will apply
    // a FRESH delta on top of already-applied ratings; the original contribution stays "baked in"
```

### 5.5 Maintenance algorithms

```
FUNCTION recalculateWdl():                              // idempotent; safe to run repeatedly
    tally[playerId] = (0,0,0) for every player
    FOR each COMPLETED tournament, each round, each match:
        skip pending and bye matches                    // byes NOT counted here (unlike standings!)
        update tally for both sides from the result
    write tally back onto every player; persist

FUNCTION recalculateMatchRatingDeltas():                // idempotent; display-only
    FOR each COMPLETED, RATED tournament:
        skip if already fully filled, or if not rated, or if ratingSnapshot is empty (can't reconstruct)
        reconstruct each roster player at their PRE-tournament rating from ratingSnapshot,
            but keep their CURRENT gamesPlayed (best-effort approximation — a backfilled delta
            may land in the wrong K-factor tier, e.g. 40 vs 20, if gamesPlayed has since grown
            past 30; this is a documented, accepted caveat, not a bug to fix)
        calculateAndApplyMatchDeltas(reconstructed, t.rounds, t.ratingType)   // writes deltas only
    RETURN counts: (filled, skippedNoSnapshot, alreadyDone, notRated)
```

### 5.6 Offline sync queue

```
FUNCTION queue(players, tournament?):
    entries = load raw JSON list from shared_preferences key 'pending_tournament_finalizations_v1'
    IF tournament given: remove any existing entry for the same tournament.id first (no dupes)
    append { tournament: tournament?.toJson(), players: players.map(toJson) }
    write back

FUNCTION trySyncAll(saveTournament, savePlayers):
    entries = load; if empty, return 0
    remaining = []; synced = 0
    FOR each entry:
        TRY: savePlayers(decode(entry.players));
             IF entry.tournament present: saveTournament(decode(entry.tournament, using a
                 player-id map built from the just-saved players))
             synced += 1
        CATCH: remaining.add(entry)      // stays queued for next attempt, no backoff
    write remaining; RETURN synced
```

### 5.7 Migration & backup/restore

```
FUNCTION migrate(onProgress?):
    start stopwatch; errors = []
    players = LocalDb.loadPlayers()               // hard failure aborts with an error
    tournaments = LocalDb.loadTournaments(players) // failure recorded, migration continues
    FOR each batch of <=50 players: TRY upsert; CATCH record error, continue with next batch
    FOR each tournament: TRY save (metadata+roster+matches); CATCH record error, continue
    RETURN { playersMigrated, tournamentsMigrated, matchesMigrated, errors[], elapsedTime }
    // idempotent via upsert -> safe to re-run after partial failure

FUNCTION backup(players, tournaments):
    json = { version: 1, created_at: now, players: [...], tournaments: [...] }
    write to {documentsDir}/chess_backup_<ISO8601 with ':' and '.' replaced by '-'>.json

FUNCTION restore(file, savePlayers, saveTournaments):
    payload = parse(file); IF payload.version != 1: THROW ("Unrecognised backup version")
    decode players -> map by id; decode tournaments using that player map
    savePlayers(...); saveTournaments(...)          // UPSERT ONLY — never deletes anything
    RETURN the restored records for in-memory merge
```

---

## 6. Persistence / Service Layer Contract

Implement these exact service surfaces so `main.dart`'s single state owner can swap between
Supabase (online) and the local snapshot (offline) transparently:

| Service | Responsibility | Required signatures |
|---|---|---|
| `SupabaseDb` | PostgREST persistence | `init()`, `initPublic({schoolCode})`, `reset()`, `loadPlayers()`, `savePlayers(List<Player>)`, `savePlayer(Player)`, `deletePlayer(String)`, `loadTeams()`, `saveTeams(List<RosterTeam>)`, `deleteTeam(String)`, `loadTournaments(List<Player>)`, `saveTournament(Tournament)` (3-step: metadata → tournament_players → matches), `saveTournaments(List<Tournament>)`, `deleteTournament(String)` |
| `LocalDb` | shared_preferences snapshot cache | mirrors `SupabaseDb`'s load/save surface, plus `clearAll()` (dev helper) |
| `RatingService` | Elo | `expectedScore`, `actualScore`, `kFactor`, `calculateTournamentChanges`, `calculateAndApplyMatchDeltas`, `applyChanges` |
| `PendingSyncService` | offline queue | `queue({required players, Tournament? tournament})`, `pendingCount()`, `trySyncAll({saveTournament, savePlayers})` |
| `LocalDbBackup` | JSON file backup/restore | `backup()`, `listBackups()`, `restore(File, {savePlayers, saveTournaments})`, `delete(File)` |
| `MigrationService` | one-time local→Supabase push | `migrate({onProgress})` |

`SupabaseDb.loadTournaments` must do the client-side "join" exactly like the source: 3 queries
(tournament metadata, bulk `tournament_players` via `IN`, bulk `matches` via `IN`, ordered by
`round, board`), reassembled into `Tournament` objects in Dart — there is no SQL join, CTE, or
stored procedure anywhere in this app.

**Auth/session calls to wire up:** `signInWithPassword`, `signInWithOtp` (invite), `signOut`,
`updateUser` (password), `onAuthStateChange` stream, local-only `currentUser`/`currentSession`
reads (never require a network round-trip just to check login state).

---

## 7. Legacy Quirks & Edge Cases That Must Survive the Rebuild

These are documented, intentional behaviors from the original app. Do not silently "fix" them.

1. IDs are **not UUIDs** for app-created entities: players get sequential 6-digit strings
   (`nextId`); tournaments/teams get `DateTime.now().millisecondsSinceEpoch` /
   `.microsecondsSinceEpoch` strings. Collision risk under multi-writer scenarios is accepted at
   club scale. `copyWith(id: originalId)` preserves IDs across edits.
2. No timezone normalization anywhere — `DateTime.parse`/`toIso8601String` are used as-is,
   device-local. Decide on a consistent policy for the rebuild (recommend UTC) but be aware this
   differs from the source.
3. Backup filename sanitization is a manual string replace (`:`→`-`, `.`→`-`), not a general
   sanitizer — keep it simple like the original, or upgrade deliberately and document the change.
4. Backup listing treats **any** filename containing `chess_backup_` as a backup candidate —
   preserve this loose contract or tighten it, but don't silently assume a stricter format.
5. Enum decoding from stored/legacy data is **lenient**: unknown/renamed enum values silently
   coerce to a default (`MatchResult`→pending, `gender`→male, `memberStatus`→member,
   `format`→swiss, `status`→draft) rather than throwing. This masks data corruption on purpose
   in the source app; decide whether to keep this leniency or add strict validation, but pick
   one intentionally.
6. Tiebreak keys are parsed via `split('_')` on `"winnerId_loserId"` — safe only because IDs are
   pure digits; a non-numeric ID scheme would break this parsing.
7. `Player.fromJson` in the source app has a legacy-migration fallback: derive `firstName`/
   `lastName` from a single old `name` field if present, and both rating fields from a single
   old `rating` field (default 1500) if the split fields are absent. Since this is a **clean
   rebuild** with a fresh schema, you likely do NOT need this legacy fallback — but note it
   existed in case old export files need importing.
8. `saveTournament`'s 3-step upsert (metadata → roster → matches) is **not** wrapped in a DB
   transaction — partial-write risk is accepted and mitigated only by the offline queue (which
   re-sends the whole tournament object on retry), not by DB-level atomicity.
9. Player soft-delete (`is_active`) and tournament/team hard-delete are two genuinely different
   deletion models in the same app — keep both, don't unify them into one.
10. `main.dart`'s login gate deliberately does **not** call `SupabaseDb.init()` synchronously as
    part of determining login state (that call can throw when offline) — login state and data
    loading must fail independently of each other.
11. Standings are recomputed on every access (no memoization) — O(rounds × matches) per read.
    Acceptable at club scale; don't over-engineer caching unless profiling says otherwise.
12. On every successful reload, in-memory lists are **cleared then fully replaced**, never
    appended on top of existing state — this avoids duplicate rows after a re-login.

---

## 8. Tests to Ship

Recreate the original three-file test suite (or an equivalent covering the same ground) so
`flutter test` verifies the algorithmic core:

- **`test/pairing_test.dart`** — individual Swiss engine regression tests: round-1 seeding,
  score-group ordering in later rounds, rematch avoidance, color-clash avoidance and repair,
  bye rotation fairness, exhaustion detection (`allPairsPlayed`), attempt-cap rescue pairing.
- **`test/team_pairing_test.dart`** — team Swiss engine + team standings: board construction
  including Olympiad color-flip on even boards, forfeited-board byes, team bye handling, team
  standings sort order.
- **`test/pending_sync_test.dart`** — offline queue: enqueue/dedupe-by-tournament-id, drain
  success removes the entry, drain failure keeps it queued, full-roster reconstruction from a
  queued tournament entry.

Additionally, add coverage for the pieces most likely to regress silently: the two-rounding-
strategies Elo divergence (§5.1), late-joiner point seeding, bye-vs-W/D/L-recalc asymmetry
(§5.5 vs §5.3), and knockout bracket seeding for non-power-of-2 fields.

---

## 9. Suggested Orchestration (multi-agent task split)

Recommended way to split this across sub-agents/tasks so nothing in §4 gets dropped. Each task
should end by cross-checking its slice of the §4 checklist before being marked complete.

1. **Schema & RLS agent** — implement §2 in the actual Supabase project (tables, indexes, FKs
   with cascade, RLS policies, the `my_school_id()`/`my_role()` helpers, and a decision on the
   signup→profile trigger). Output: migration SQL file(s) + a short doc of what RLS policies
   were created and why.
2. **Models agent** — `Player`, `Team`/`TeamRoundPairing`/`RosterTeam`, `Tournament`/
   `ChessMatch`/`TournamentStanding`/`TeamStanding`, all enums, JSON (de)serialization.
3. **Ratings & pairing engine agent** — `rating_service.dart` and all of `BracketGenerator`
   (round robin, knockout, individual Swiss, team Swiss, color assignment, standings,
   tiebreaks) exactly per §5. This is the highest-risk, highest-fidelity piece — build the test
   suite (§8) alongside it, not after.
4. **Persistence/services agent** — `supabase_db.dart`, `local_db.dart`,
   `pending_sync_service.dart`, `local_db_backup.dart`, `migration_service.dart`, per the
   contract in §6.
5. **App shell & auth agent** — `main.dart`'s `_AuthGate`/`_MainScreenState`/`_DashboardPage`,
   `login_screen.dart`, the offline-safe session gate (§4.1), single-state-owner wiring for
   every page.
6. **Pages/UI agent(s)** — `players_page.dart`, `player_profile_page.dart`, `teams_page.dart`,
   `tournaments_page.dart`, `f2f_tournament_view.dart`, `online_tournament_view.dart`,
   `accounts_page.dart`, `player_picker_widget.dart`. Material 3 dark theme.
7. **QA/verification agent** — runs `flutter test` and `flutter analyze` (zero warnings), walks
   the entire §4 checklist item by item against a running build (web + at least one native
   target), spot-checks the codebase against every rule in §10 (file sizes, naming,
   no-logic-in-widgets, no dead code), flags any gap back to the owning agent, and only then
   signs off the build as complete.

**Do not let the pages/UI agent invent business logic.** Any pairing/rating/standings decision
made inside a page widget instead of the models/services layer is a bug — page widgets are
presentational only, per §0 rule 3.

---

## 10. Clean Code & Codebase Structure Standards

The original app's own audit (edge-case scan) found zero `TODO`/`FIXME`/dead-code/debug-print
litter — hold the rebuild to that same bar, but go further on organization: several original
files (`tournaments_page.dart` at 2195 lines, `f2f_tournament_view.dart` at 1980 lines,
`players_page.dart` at 1596 lines) are too large for a clean rebuild. Don't reproduce that.

### 10.1 File & folder organization
- **One public class per file.** Filenames are `snake_case` and match their primary class
  (`player_profile_page.dart` defines `PlayerProfilePage`).
- **Soft cap ~400 lines per file.** If a page file is growing past that, extract:
  - Dialogs → their own file under `pages/<feature>/dialogs/`.
  - Reusable sub-widgets (cards, list tiles, board rows, stat chips) → `pages/<feature>/widgets/`
    or `widgets/` if used across features.
  - Non-trivial local logic (e.g. a page's filter/sort helpers) → a small pure-function helper
    file or a `*_controller.dart` if it's stateful, so the page file itself stays a thin
    composition root (build methods + wiring, not business logic).
- Group by **feature**, not by widget type, once a page needs splitting — e.g.
  `pages/tournaments/tournaments_page.dart`, `pages/tournaments/tournament_setup_dialog.dart`,
  `pages/tournaments/round_board_editor.dart` — rather than dumping everything flat into
  `pages/` or a generic `widgets/` bucket.
- Keep the top-level structure from §1 intact (`models/`, `services/`, `pages/`, `widgets/`,
  `test/`) — feature subfolders live **inside** `pages/`, not as new top-level siblings.

### 10.2 Separation of concerns
- **No business logic inside widget `build()` methods or event handlers.** Rating math,
  pairing, and standings live only in `models/tournament.dart` and
  `services/rating_service.dart`, per §5 — pages only call them and render the result.
- **`_MainScreenState` (or its rebuilt equivalent) is the only caller of `SupabaseDb`.** If a
  page or dialog needs data it doesn't have, that's a sign it's missing a callback prop, not a
  reason to reach into the service layer directly.
- Model classes own their own JSON (de)serialization (`toJson`/`fromJson`) — don't scatter
  field-mapping logic into the service layer or the UI.

### 10.3 Naming & style
- Standard Dart/Flutter conventions: `UpperCamelCase` for types, `lowerCamelCase` for members
  and locals, `SCREAMING_SNAKE_CASE` only for true compile-time constants if used at all (prefer
  descriptive `static const` fields instead, e.g. `swissMaxAttempts = 20000`,
  `migrationBatchSize = 50` — collect these in one clearly-named place rather than scattering
  bare numeric literals through the pairing/migration code).
- Enums and their string names must match §2/§4 exactly (`format`, `status`, `rating_type`,
  `member_status`, `result` values) since they round-trip through Supabase as text.
- Every public method in `BracketGenerator` and `RatingService` gets a short doc comment stating
  its purpose and pointing back at the relevant §5 subsection, so future readers don't have to
  reverse-engineer the algorithm again.

### 10.4 Error handling consistency
- Follow the source app's pattern exactly (don't introduce a second error-handling style):
  persistence operations catch and return `bool`/queue-on-failure (§4.10); auth operations catch
  `AuthException` distinctly and surface `e.message`; nothing throws an uncaught exception up to
  a widget's `build()`.
- No swallowed `catch (_) {}` blocks that silently do nothing — even a "best-effort, drop on
  failure" path (like routine profile edits, §4.10) should be an explicit, commented decision,
  not an empty catch block that looks accidental.

### 10.5 Hygiene
- No `print()`/`debugPrint()`/commented-out code left in the final build.
- No `TODO`/`FIXME` placeholders — if something is genuinely deferred, it belongs in the PR
  description or a tracked issue, not a code comment nobody will revisit.
- Run `dart format .` and `flutter analyze` with the `flutter_lints` ruleset clean (zero
  warnings) before any task is marked done.
- Tests in `test/` are organized one file per concern (§8), not one giant test file.

---

*This document was compiled from a full reverse-engineering pass of the original Chess Manager
codebase (migration phases 1–6) and is the authoritative functional/technical spec for this
rebuild. If anything here seems to conflict with a simpler or more "obvious" implementation,
trust this document — the original app's behavior was extracted directly from its source code,
not guessed at.*
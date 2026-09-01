# Chess Manager — Project Architecture Overview (Migration Phase 1)

A complete scan and documentation of the `ChessManager` repository, capturing
the tech stack, module responsibilities, entry points, and every system
capability the application provides.

---

## 1. Tech Stack Components

| Layer | Technology | Notes |
|-------|-----------|-------|
| Language | **Dart** (SDK `>=3.0.0 <4.0.0`) | Records, sealed-style enums, pattern matching used throughout |
| UI framework | **Flutter** (Material Design, `uses-material-design`) | Single shared codebase |
| Primary DB / backend | **Supabase** (Postgres) via `supabase_flutter` `^2.15.0` | PostgREST client; direct table access protected by Row-Level Security (RLS). No ORM — raw table builders/upserts. |
| Local persistence | **`shared_preferences`** `^2.2.2` | JSON snapshot cache + offline write queue |
| File storage | **`path_provider`** `^2.1.5` | Documents dir for backup/restore JSON files |
| Linting | **`flutter_lints`** `^3.0.0` | Dev/test tooling |
| Testing | **`flutter_test`** | Unit tests only (no integration/e2e) |
| Build config | Compile-time env via `--dart-define-from-file=.env` | No runtime `.env` loading |
| Deployment | **Netlify** (`netlify.toml` SPA redirect) for web | Manual deploys of `build/web` |

### Supported platforms
Windows, macOS, Linux, Android, iOS, and web. Native runners under
`android/`, `ios/`, `linux/`, `macos/`, `windows/`, `web/` are standard
generated Flutter scaffolding (no custom native logic).

### Database layout (Supabase tables used by the code)
- `players` — one row per player (snake_case columns; `school_id` scoped)
- `tournaments` — tournament metadata only
- `tournament_players` — roster snapshot (which players joined which tournament, with the rating at enrollment time)
- `matches` — one row per `ChessMatch`
- `teams` — reusable saved team rosters (independent of tournaments)
- `profiles` — user → `school_id` mapping (auth/role context)
- `schools` — lookup for public-access school code resolution
- `tournaments.teams`, `tournaments.team_pairings`, `tournaments.rating_snapshot`, `tournaments.wdl_snapshot`, `tournaments.tiebreak_results` — jsonb columns

---

## 2. Project Directory Structure & Module Responsibilities

```
lib/
  main.dart                     # Entry point, auth gate, top-level data/sync orchestration,
                                #   MainScreen/PublicScreen state, Dashboard
  demo_data.dart                # Sample dataset, seeded when --dart-define=SEED_DEMO=true
  models/
    player.dart                 # Player model + enums (gender, member status) + JSON
    team.dart                   # Team / TeamRoundPairing / RosterTeam models + JSON
    tournament.dart             # Tournament, ChessMatch, standings, tiebreaks, and the
                                #   Swiss / round-robin / knockout / team pairing engines
  pages/
    accounts_page.dart          # School account management (admin-only: invites, roles, password)
    f2f_tournament_view.dart    # In-person tournament detail UI (pairings, match entry, standings)
    login_screen.dart           # Email/password auth screen
    online_tournament_view.dart # Import + enter externally-run (online) tournaments
    player_profile_page.dart    # Individual player detail / history / edit
    players_page.dart           # Roster CRUD (list, search, sort, add/edit/delete)
    teams_page.dart             # Saved reusable team rosters CRUD
    tournaments_page.dart       # Tournament list, creation, and mutation logic + setup dialog
  services/
    supabase_db.dart            # Supabase read/write layer (source of truth when online)
    local_db.dart               # shared_preferences snapshot cache (offline read fallback)
    local_db_backup.dart        # JSON backup/restore + BackupManagerDialog
    pending_sync_service.dart   # Offline write queue (players/tournaments) + Sync Now
    rating_service.dart         # FIDE Elo calculations (expected score, K-factor, apply)
    migration_service.dart      # One-time local-storage → Supabase migration
  widgets/
    player_picker_widget.dart   # Reusable searchable/sortable player selector
test/
  pairing_test.dart             # Individual Swiss pairing engine regression tests
  team_pairing_test.dart        # Team Swiss pairing + standings tests
  pending_sync_test.dart        # Offline sync queue tests
```

### Module responsibilities in detail

**`lib/main.dart`** — the application root. Owns:
- `main()`: binding init, Supabase initialization, optional demo-data seeding, `runApp`.
- `_AuthGate`: subscribes to Supabase auth state; routes to `PublicScreen` or `MainScreen` based purely on the locally-persisted session (offline-safe).
- `PublicScreen`: read-only view for unauthenticated visitors (Players/Teams/Tournaments); loads via `SupabaseDb.initPublic()` with local-snapshot fallback, plus an offline banner.
- `MainScreen` (`_MainScreenState`): holds the in-memory `players`/`tournaments`/`teams` lists **and is the only place that talks to `SupabaseDb`**. All pages receive data + callbacks as props and mutations flow back up. Owns persistence helpers (`_persistTournament`, `_persistNewPlayer`, `_finalizeTournament`, `_addLatecomers`, `_syncPendingNow`), maintenance (`_recalculateWdl`, `_recalculateMatchRatingDeltas`), and full CRUD for players/tournaments/teams.
- `_DashboardPage`: stat cards (members, guests, avg rating, tournaments, active), top players, recent tournaments, and maintenance actions (backup/restore, migrate, recalc W/D/L, backfill match deltas).

---

## 3. High-Level Entry Points

This is a **client-side Flutter application**. There are no separate worker
processes or standalone CLI commands. All "background"-style work runs
in-process from UI actions.

### Server / app initialization — `lib/main.dart` `main()`
1. `WidgetsFlutterBinding.ensureInitialized()`
2. Verify `SUPABASE_URL` / `SUPABASE_ANON_KEY` compile-time defines; throws if missing.
3. `Supabase.initialize(...)`
4. If `SEED_DEMO=true` (via `--dart-define`), seed `LocalDb` with `DemoData`.
5. `runApp(ChessManagerApp())` → `MaterialApp` → `_AuthGate`.

### Auth-boundary entry — `_AuthGate`
- `_AuthGateState` listens to `Supabase.instance.client.auth.onAuthStateChange`.
- Logged-in → `MainScreen`; logged-out → `PublicScreen` (read-only public view with an admin sign-in entry point).

### Data-load entry points
- **`MainScreen._loadAll()`**: calls `SupabaseDb.init()`, drains the pending sync queue, loads players/tournaments/teams, snapshots to `LocalDb`; on failure falls back to the cached snapshot (`LocalDb.load*`) and sets the offline flag.
- **`PublicScreen._load()`**: loads read-only data via `SupabaseDb.initPublic()` (public RLS policy by school code), else falls back to the local snapshot.

### Sync triggers
- **On launch**: `PendingSyncService.trySyncAll(...)` inside `_loadAll()`.
- **Manual**: `Sync Now` button (`_syncPendingNow`).

### Tests (entry points for verification)
`flutter test` runs `test/pairing_test.dart`, `test/team_pairing_test.dart`, and `test/pending_sync_test.dart`.

---

## 4. System Capabilities Summary

### Core domain — tournaments & pairing
- **Tournament formats** (enum `TournamentFormat`): **Swiss**, **Round Robin**, **Knockout** (single elimination, standard power-of-2 bracket seeding via `_bracketSeedOrder`).
- **Swiss pairing engine** (`BracketGenerator.generateSwissNextRound`): global backtracking search across the whole field ordered by score then the standings' tiebreak chain. Hard constraints first (rematches, forced 3rd-consecutive color), relaxed in stages (rematches only after color-respecting attempts) via `_matchAll` / `_maxMatch`; local color-clash repair pass (`_repairColorClashes`); fair bye rotation (`_hadBye`); automatic stop when `allPairsPlayed` (further rounds would be forced rematches).
- **Round Robin** (`generateRoundRobin`): Berger circle rotation with alternating colors.
- **Knockout** (`generateKnockout`, `generateKnockoutNextRound`): single elimination with bracket seeding.
- **Latecomer support** (`Add Latecomer`): join players into an in-progress Swiss tournament; they start with the standard **0.5-point late-joiner handicap** (detected by first-appearance round in `standings`).
- **Team tournaments** (Team model + `TeamRoundPairing`): fixed-board teams, Olympiad-style board color alternation (`_buildTeamPairingMatches`), short-roster forfeits counted as byes, team Swiss pairing engine (`_matchAllTeams` / `_maxMatchTeams` / `_repairTeamColorClashes` / `_assignWhiteTeam`), team standings from board points, automatic stop when `allTeamPairsPlayed`.

### Ratings
- **FIDE-formula Elo** (`RatingService`): expected score via `1 / (1 + 10^((Rb−Ra)/400))`, tiered K-factor (40 new/provisional under 30 games, 20 normal <2400, 10 elite).
- Two rating pools: **blitz** and **rapid** (`RatingType`).
- Per-game match rating deltas (`whiteRatingDelta` / `blackRatingDelta`) written onto each `ChessMatch` and rolled up per tournament (`calculateAndApplyMatchDeltas`); tournament-level accumulation and `applyChanges` for applying to player records.
- **Undo support** via pre-finalization snapshots (`ratingSnapshot`, `wdlSnapshot`).

### Standings & tiebreaks
- `Tournament.standings` computes: score points, wins/draws/losses, progressive (cumulative) score, Buchholz, Buchholz Cut-1, Sonneborn-Berger, direct encounter (head-to-head, including injected tiebreaker results), plus wins and rating as final tiebreaks.
- Ranking sort order: points → Buchholz-Cut1 → Buchholz → Progressive → Direct Encounter → Sonneborn-Berger → Wins → Rating.
- **Team standings** computed from team match points + summed board points per round.
- **Tiebreaker submission** flow (explicit armageddon/fast tiebreak records injected into standings).

### Player & team roster management
- **Player roster CRUD**: ratings (blitz/rapid), FIDE titles, gender, member/guest status, membership status/active toggle, college/school, program, email/phone, win/draw/loss records; auto-assigned 6-digit player IDs.
- **Player profile page**: full detail, tournament history, profile edits, active/inactive toggle, delete.
- **Filters/search/sort** on the players page; filter by active, guests, name/title/school.
- **Saved reusable teams** (`RosterTeam`): build a roster once on the Teams page and reuse it across many team tournaments.

### Online tournament import
- Import externally-run tournaments (`online_tournament_view.dart`): enter format, pairings, and results for a completed online tournament, then calculate and apply rating changes.

### Offline resilience
- **Offline writes**: new players, new/updated tournaments, and tournament finalization fall back to a local queue (`PendingSyncService`, backed by `shared_preferences`) when Supabase can't be reached; queued entries are drained on next launch and via the **Sync Now** button, and each tournament's full roster is stored so it can be reconstructed at sync time.
- **Offline reads**: every successful load is snapshotted to `LocalDb`; if Supabase is unreachable at launch, the last snapshot is shown instead of an empty app, with an offline banner and retry.
- **Offline-safe auth**: login state depends only on the locally-persisted Supabase session (no network call), so a previously-authenticated user can open the app offline.

### Admin / account management
- **Authentication**: email/password sign-in (`LoginScreen`), routed via `_AuthGate`.
- **Accounts page** (admin-only for `school_admin` / `super_admin`): list all accounts in the school, invite new users (Supabase invite/magic-link flow, player role by default), change roles, change own password.

### Backup, restore & migration
- **Backup & Restore** (`LocalDbBackup` + `BackupManagerDialog`): export current roster/tournaments to a timestamped JSON file in the documents directory; list/delete backups; restore pushes the file back to Supabase as an **upsert** (never deletes anything not in the backup), merging restored records into live state.
- **Migrate Local Data to Supabase** (`MigrationService.migrate()`): one-time idempotent push from `LocalDb` (shared_preferences) to Supabase in batches of 50 for players, then each tournament (metadata + roster + matches), reporting progress and per-item errors and timing.

### Dashboard & maintenance
- **Dashboard**: member/guest counts, average rating (blitz/rapid toggle), tournament count, active tournaments, top-5 players, recent tournaments, status chips.
- **Maintenance actions**: Recalculate W/D/L from tournament history (idempotent replay of completed tournaments), Backfill per-match rating changes for pre-existing tournaments (from `ratingSnapshot`, with skips reported for non-rated or snapshot-less tournaments), Backup & Restore, and Migrate to Supabase.

### Public read-only view
- `PublicScreen` offers the same Players/Teams/Tournaments views to unauthenticated visitors (school-code based public RLS access) with offline snapshot fallback — no write capability.

---

## Architecture Notes (for migration context)

- **Single state owner**: `_MainScreenState` owns all in-memory collections and is the **only** caller of `SupabaseDb`. Pages are presentational and receive callbacks; mutations flow back up to `MainScreen`.
- **DB swap abstraction**: the original `LocalDb` (shared_preferences) and `SupabaseDb` expose the same `loadPlayers/savePlayers/loadTournaments/saveTournaments` surface, which is what made the local→Supabase migration seamless (see `migration_service.dart`).
- **Failure model**: every persistence path either hits Supabase or — for create/finalize/update-tournament and new-player operations — falls back to `PendingSyncService.queue(...)`. Routine player profile edits save directly and are best-effort (would be dropped if offline).

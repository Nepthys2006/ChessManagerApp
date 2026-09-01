# Chess Manager — Third-Party Integrations Report (Migration Phase 5)

A scan of package configuration, external API calls, SDK initializations,
environment variables, webhooks, and asynchronous/background processing in
the repository.

---

## 0. Executive Summary

**ByIdentity, Chess Manager integrates with exactly ONE third-party service:
Supabase** (database + auth backend). There are **no** integrations for
payment gateways, email/notification services, AI APIs, analytics, storage
buckets, or background message queues. There are **no webhooks** (outbound or
inbound), **no cron jobs**, and **no worker/async background tasks** beyond a
client-side, on-launch sync of an offline write queue.

The full dependency surface is defined in `pubspec.yaml` and `pubspec.lock`:

```
Direct dependencies (main):
  path_provider      ^2.1.5     filesystem paths (documents dir for backups)
  shared_preferences ^2.2.2     local JSON store (offline cache + sync queue)
  supabase_flutter   ^2.15.0    Supabase SDK (Auth + PostgREST client)
                                → pulls transitive `supabase` v2.13.0,
                                  `http`, `http_parser`

Dev/test dependencies:
  flutter_test, flutter_lints ^3.0.0

Transitive (auto): http, http_parser, flutter_web_plugins, and the
platform implementation packages for path_provider & shared_preferences
(android, foundation/ios, linux, windows, web…)
```

No `package.json` / `requirements.txt` / `go.mod` / `Cargo.toml` / `Gemfile`
exist — this is a Dart/Flutter-only project.

---

## 1. Third-Party Services Integrated

### 1.1 Supabase (the only integrated service)

| Aspect | Detail |
|--------|--------|
| Purpose | Primary database (Postgres via PostgREST) **and** authentication (GoTrue) backend |
| SDK | `supabase_flutter` `^2.15.0` (transitive core package `supabase` `v2.13.0`) |
| Init | `Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey)` in `lib/main.dart:38`) |
| Auth features used | `signInWithPassword`, `signInWithOtp` (magic-link invite), `signOut`, `updateUser` (password), `onAuthStateChange`/`currentSession`/`currentUser` |
| Data features used | PostgREST: `select / upsert / update / delete / eq / inFilter / order / single` across tables `players`, `teams`, `tournaments`, `tournament_players`, `matches`, `profiles`, `schools` |
| Edge functions / RPC | **None** (no `.rpc()` calls, no edge function invocations) |
| Realtime subscriptions | **None** (no `channel()`/`subscribe()`; the only stream is `onAuthStateChange`) |
| Storage buckets | **None** (no `storage` API usage) |
| Type of key | **Anonymous/publishable key** — safe to embed client-side, authorization delegated to RLS policies. Read-only public access via `initPublic()` using a hard-coded default school code (see §3) |

### 1.2 Services explicitly NOT integrated
- **Payment / billing:** none. No Stripe, PayPal, etc. (No financial logic — see Phase 3.)
- **Email / transactional:** none. Auth emails (magic links, password reset) are sent *by Supabase's managed Auth service*; no email provider (SendGrid, Postmark, SES) is configured in-repo. Account invite uses Supabase's `signInWithOtp`.
- **AI / ML APIs:** none.
- **Analytics / crash reporting:** none (no Sentry, PostHog, Firebase Analytics, Mixpanel, etc.).
- **Storage:** none (backup/restore uses the device's local documents directory via `path_provider`, NOT cloud storage).
- **Push notifications / deep links:** none.

### 1.3 Deployment platform
- **Netlify** — web hosting only, via `netlify.toml` (SPA redirect rule `/*` → `/index.html`, status 200). Manual deploys (`flutter build web --dart-define=...` then upload `build/web`). No Netlify Functions, no build automation in-repo.

---

## 2. Outbound & Incoming Webhooks

**None.**

- **Outbound webhooks:** the app makes no HTTP webhook calls. Its only network
  traffic is to the Supabase PostgREST/Auth REST API (JSON over HTTPS).
- **Incoming webhook handlers:** there is no server-side handler of any kind
  in this repository (client-only Flutter app). There is therefore **no
  webhook payload schema and no webhook validation secret** to document.
- Related capability that does NOT exist: **Supabase Edge Functions
  (./functions/), Supabase Database Webhooks, or a `supabase/config.toml`**
  are absent from the repo. If the migration needs inbound webhooks or
  outbound notifications, they must be added to the Supabase project
  (functions/webhooks) — none exist today.

---

## 3. Environment Variables

All configuration is **compile-time** via `--dart-define-from-file=.env`
(no runtime environment / `.env` file loading — it is baked into the binary
at build time; `String.fromEnvironment` / `bool.fromEnvironment`).

### 3.1 Variables actually consumed by the app

| Variable | Where read | Type | Description | Fallback / default | Sensitive? |
|----------|-----------|------|-------------|--------------------|------------|
| `SUPABASE_URL` | `lib/main.dart:26` (`String.fromEnvironment`) | `String` | Supabase project REST/Auth base URL | **None** — `main()` throws a `StateError` if empty | No (public project URL) |
| `SUPABASE_ANON_KEY` | `lib/main.dart:27` (`String.fromEnvironment`) | `String` | Supabase publishable/anon key | **None** — throws if empty | Publishable (safe to embed); **still `.gitignore`-protected** |
| `SEED_DEMO` | `lib/demo_data.dart:16` (`bool.fromEnvironment`) | `bool` | UI-preview flag; when `true`, seeds the local snapshot with sample data (no live backend needed) | `false` (off by default) | No |

**Behavioral details:**
- If either `SUPABASE_URL` or `SUPABASE_ANON_KEY` is empty, `main()` throws:
  `StateError('SUPABASE_URL/SUPABASE_ANON_KEY are not set. Run with
  --dart-define-from-file=.env …')` (`main.dart:32–36`).
- `SEED_DEMO=true` triggers `DemoData.seed()` which overwrites the **local
  snapshot** (`LocalDb`) only — real Supabase data is untouched.

### 3.2 `.env` file
- `.env` at repo root (git-ignored; `.gitignore` excludes it) holds the two
  real values. Only present locally, never committed.
- `netlify.toml` comments confirm the same approach for web deploys:
  `flutter build web --dart-define=…`.
- **No variables** for secrets like `SERVICE_ROLE_KEY` exist in-repo. The code
  comments explicitly note that invite flows would need a service-role key but
  deliberately use the anon path instead (`accounts_page.dart:484`).

### 3.3 Platform-native config files
- `android/local.properties`, `macos/.../AppInfo.xcconfig`,
  `web/manifest.json`, `web/index.html` — standard Flutter scaffolding; none
  define custom environment variables used by the app logic.

---

## 4. Background Message Queues, Cron Jobs, Async Worker Tasks

**No server-side queues, cron jobs, or worker processes exist.** The
architecture is client-only. The only async/background activity is **in-app**
and on the client device:

### 4.1 Offline write queue (`PendingSyncService`) — the closest thing to a "queue"
- Backed by `shared_preferences` (key `pending_tournament_finalizations_v1`).
- Stores queued players/tournaments as JSON when a Supabase write fails (no
  internet).
- **Drain triggers (async tasks executed within the app's UI isolate):**
  1. On every authenticated launch: `PendingSyncService.trySyncAll(...)`
     inside `MainScreen._loadAll()` (`main.dart:503`).
  2. On button press: **Sync Now** (`_syncPendingNow`, `main.dart:642`).
- Deduplication: re-queuing the same tournament replaces the earlier entry.
- **Not a message broker** — no SQS/Kafka/Rabbit/pub-sub; strictly a local,
  single-device retry queue, drained in the foreground.

### 4.2 Other async work (client-side, no scheduler)
- `unawaited(LocalDb.savePlayers(...))` etc. — fire-and-forget snapshot writes
  after a successful load (`main.dart:531–533`).
- Data loads, finalization, migration, export/restore — all triggered by user
  actions or startup; no `Timer.periodic`, no `schedule`, no background
  isolate, no platform background execution.

### 4.3 Cron jobs / scheduled tasks
- **None.** The only `Durations` in the code are SnackBar display times
  (3–4 seconds). No `Timer`, no cloud scheduler, no scheduled edge function.

---

## 5. Migration / Phase-5 Action Items

1. **Add any desired server-side integrations** — none exist today. Candidate
   gaps to resolve during migration: cloud **storage backups** (currently
   device-local), **email notifications**, **analytics/crash reporting**, and
   **inbound webhooks / Supabase Edge Functions** if required.
2. **Secret handling:** service-role key (if ever introduced for invites) must
   never be embedded client-side; keep to anon key + RLS for the app, and move
   admin ops to an edge function/server if needed.
3. **Environment variable governance:** `SUPABASE_URL` / `SUPABASE_ANON_KEY`
   and `SEED_DEMO` are the only vars; centralize their documentation in one
   place (currently spread across README, `.env.example`, `main.dart`,
   `demo_data.dart`).
4. **Verify `.env` remains git-ignored** before any migration CI/CD work is
   added (it is listed in `.gitignore` today).

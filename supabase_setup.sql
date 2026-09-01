-- ============================================================================
-- Chess Manager — Supabase setup (§2 of ORCHESTRATOR_BUILD_PROMPT.md)
-- Run ONCE in: Supabase Dashboard → SQL Editor → New query → Run
-- Idempotent-ish: uses IF NOT EXISTS / OR REPLACE. Safe to re-run.
-- NO secrets in this file. All authorization is enforced by RLS below.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

create table if not exists public.schools (
  id   uuid primary key default gen_random_uuid(),
  code text not null unique               -- e.g. 'UMCCC'; resolved via .eq('code', code).single()
);

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id),
  role       text not null default 'player' check (role in ('player','school_admin','super_admin')),
  school_id  uuid references public.schools(id),
  created_at timestamptz not null default now()
);

create table if not exists public.players (
  id            text primary key,          -- app-generated sequential 6-digit string, >=100000
  school_id     uuid not null references public.schools(id),
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
create index if not exists idx_players_school_id on public.players (school_id);
create index if not exists idx_players_last_name on public.players (last_name);

create table if not exists public.teams (
  id         text primary key,             -- app-generated
  school_id  uuid not null references public.schools(id),
  name       text not null,
  player_ids jsonb not null default '[]'  -- ordered array of player id strings = board order; NOT FK-enforced
);
create index if not exists idx_teams_school_id on public.teams (school_id);

create table if not exists public.tournaments (
  id               text primary key,       -- ms-epoch string
  school_id        uuid not null references public.schools(id),
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
  teams            jsonb not null default '[]',    -- Team[] snapshot, iff team tournament
  team_pairings    jsonb not null default '[]',   -- TeamRoundPairing[][] parallel to rounds
  created_at       timestamptz not null default now()
);
create index if not exists idx_tournaments_school_id on public.tournaments (school_id);

create table if not exists public.tournament_players (
  tournament_id text not null references public.tournaments(id) on delete cascade,
  player_id     text not null references public.players(id),
  blitz_rating  int not null,
  rapid_rating  int not null,
  primary key (tournament_id, player_id)
);
create index if not exists idx_tournament_players_tid on public.tournament_players (tournament_id);

create table if not exists public.matches (
  id                 text primary key,     -- e.g. 'rr_0_0', 'sw_1_0', 'ko_1_1', 'tsw_...'
  tournament_id      text not null references public.tournaments(id) on delete cascade,
  round              int not null,
  board              int not null,
  white_player_id    text references public.players(id),   -- null = bye
  black_player_id    text references public.players(id),   -- null = bye
  result             text not null default 'pending'
                       check (result in ('pending','whiteWins','blackWins','draw','bye')),
  white_rating_delta int,                  -- null until finalize or backfill
  black_rating_delta int
);
create index if not exists idx_matches_tid_round_board on public.matches (tournament_id, round, board);

-- ---------------------------------------------------------------------------
-- 2. Helper functions (security definer: avoid recursive RLS on profiles)
-- ---------------------------------------------------------------------------

create or replace function public.my_school_id()
returns uuid language sql stable security definer set search_path = public as $$
  select school_id from public.profiles where id = auth.uid()
$$;

create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- 3. RLS — enable everywhere, then policies
--    (authorization boundary lives HERE, not in the app)
-- ---------------------------------------------------------------------------

alter table public.schools      enable row level security;
alter table public.profiles     enable row level security;
alter table public.players      enable row level security;
alter table public.teams        enable row level security;
alter table public.tournaments  enable row level security;
alter table public.tournament_players enable row level security;
alter table public.matches      enable row level security;

-- schools: public (anon) select — for initPublic(schoolCode) resolution
drop policy if exists "public read schools" on public.schools;
create policy "public read schools" on public.schools
  for select to anon, authenticated using (true);

-- players / tournaments / teams: PublicScreen (anon) is read-only.
-- NOTE: the original app resolves ANY school code client-side and filters rows
-- by school_id in the app, so the anon policy exposes rows of all schools and
-- the scoping happens client-side (matches original behavior). Zero write
-- capability for anon — enforced by the absence of any insert/update/delete
-- policies for the anon role.
drop policy if exists "public read players" on public.players;
create policy "public read players" on public.players
  for select to anon, authenticated using (true);

drop policy if exists "public read tournaments" on public.tournaments;
create policy "public read tournaments" on public.tournaments
  for select to anon, authenticated using (true);

drop policy if exists "public read teams" on public.teams;
create policy "public read teams" on public.teams
  for select to anon, authenticated using (true);

-- profiles: a user can always read their own row
drop policy if exists "self read profile" on public.profiles;
create policy "self read profile" on public.profiles
  for select to authenticated using (id = auth.uid());

-- profiles: admins read school profiles
drop policy if exists "admins read school profiles" on public.profiles;
create policy "admins read school profiles" on public.profiles
  for select to authenticated
  using (school_id = my_school_id() and my_role() in ('school_admin','super_admin'));

-- profiles: admins update school profiles (role assignment)
drop policy if exists "admins update school profiles" on public.profiles;
create policy "admins update school profiles" on public.profiles
  for update to authenticated
  using (school_id = my_school_id() and my_role() in ('school_admin','super_admin'))
  with check (school_id = my_school_id() and my_role() in ('school_admin','super_admin'));

-- players: authenticated CRUD scoped to caller's school
drop policy if exists "school select players" on public.players;
create policy "school select players" on public.players
  for select to authenticated using (school_id = my_school_id());
drop policy if exists "school insert players" on public.players;
create policy "school insert players" on public.players
  for insert to authenticated with check (school_id = my_school_id());
drop policy if exists "school update players" on public.players;
create policy "school update players" on public.players
  for update to authenticated
  using (school_id = my_school_id()) with check (school_id = my_school_id());
drop policy if exists "school delete players" on public.players;
create policy "school delete players" on public.players
  for delete to authenticated using (school_id = my_school_id());

-- teams: authenticated CRUD scoped to caller's school
drop policy if exists "school select teams" on public.teams;
create policy "school select teams" on public.teams
  for select to authenticated using (school_id = my_school_id());
drop policy if exists "school insert teams" on public.teams;
create policy "school insert teams" on public.teams
  for insert to authenticated with check (school_id = my_school_id());
drop policy if exists "school update teams" on public.teams;
create policy "school update teams" on public.teams
  for update to authenticated
  using (school_id = my_school_id()) with check (school_id = my_school_id());
drop policy if exists "school delete teams" on public.teams;
create policy "school delete teams" on public.teams
  for delete to authenticated using (school_id = my_school_id());

-- tournaments: authenticated CRUD scoped to caller's school
drop policy if exists "school select tournaments" on public.tournaments;
create policy "school select tournaments" on public.tournaments
  for select to authenticated using (school_id = my_school_id());
drop policy if exists "school insert tournaments" on public.tournaments;
create policy "school insert tournaments" on public.tournaments
  for insert to authenticated with check (school_id = my_school_id());
drop policy if exists "school update tournaments" on public.tournaments;
create policy "school update tournaments" on public.tournaments
  for update to authenticated
  using (school_id = my_school_id()) with check (school_id = my_school_id());
drop policy if exists "school delete tournaments" on public.tournaments;
create policy "school delete tournaments" on public.tournaments
  for delete to authenticated using (school_id = my_school_id());

-- tournament_players: authenticated CRUD, scoped via parent tournament
drop policy if exists "school select tournament_players" on public.tournament_players;
create policy "school select tournament_players" on public.tournament_players
  for select to authenticated
  using (tournament_id in (select id from public.tournaments where school_id = my_school_id()));
drop policy if exists "school insert tournament_players" on public.tournament_players;
create policy "school insert tournament_players" on public.tournament_players
  for insert to authenticated
  with check (tournament_id in (select id from public.tournaments where school_id = my_school_id()));
drop policy if exists "school update tournament_players" on public.tournament_players;
create policy "school update tournament_players" on public.tournament_players
  for update to authenticated
  using (tournament_id in (select id from public.tournaments where school_id = my_school_id()))
  with check (tournament_id in (select id from public.tournaments where school_id = my_school_id()));
drop policy if exists "school delete tournament_players" on public.tournament_players;
create policy "school delete tournament_players" on public.tournament_players
  for delete to authenticated
  using (tournament_id in (select id from public.tournaments where school_id = my_school_id()));

-- matches: authenticated CRUD, scoped via parent tournament
drop policy if exists "school select matches" on public.matches;
create policy "school select matches" on public.matches
  for select to authenticated
  using (tournament_id in (select id from public.tournaments where school_id = my_school_id()));
drop policy if exists "school insert matches" on public.matches;
create policy "school insert matches" on public.matches
  for insert to authenticated
  with check (tournament_id in (select id from public.tournaments where school_id = my_school_id()));
drop policy if exists "school update matches" on public.matches;
create policy "school update matches" on public.matches
  for update to authenticated
  using (tournament_id in (select id from public.tournaments where school_id = my_school_id()))
  with check (tournament_id in (select id from public.tournaments where school_id = my_school_id()));
drop policy if exists "school delete matches" on public.matches;
create policy "school delete matches" on public.matches
  for delete to authenticated
  using (tournament_id in (select id from public.tournaments where school_id = my_school_id()));

-- ---------------------------------------------------------------------------
-- 4. Auto-create profiles row on signup (spec §2 recommended option)
--    New users get role='player', school_id=null (assigned manually by admin).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- 5. Seed: the default public school code (hard-coded in the app: 'UMCCC')
-- ---------------------------------------------------------------------------
insert into public.schools (code) values ('UMCCC')
  on conflict (code) do nothing;

-- ============================================================================
-- 6. DEMO DATA — safe to keep or delete. Real users of the app will see these
--    in the UMCCC roster. To remove later, run the CLEANUP block at the end.
-- ============================================================================

insert into public.players (id, school_id, first_name, last_name, blitz_rating, rapid_rating, gender, member_status, college, program)
values
  ('100001', (select id from public.schools where code='UMCCC'), 'Alice',   'Tan',     1720, 1685, 'female', 'member', 'Faculty of Science',  'Computer Science'),
  ('100002', (select id from public.schools where code='UMCCC'), 'Bilal',   'Hassan',  1610, 1580, 'male',   'member', 'Faculty of Science',  'Physics'),
  ('100003', (select id from public.schools where code='UMCCC'), 'Chloe',   'Lim',     1845, 1810, 'female', 'member', 'Faculty of Arts',    'Economics'),
  ('100004', (select id from public.schools where code='UMCCC'), 'David',   'Okoye',   1495, 1520, 'male',   'member', 'Faculty of Science',  'Biology'),
  ('100005', (select id from public.schools where code='UMCCC'), 'Elena',   'Vasquez', 1580, 1600, 'female', 'guest',  'St. Mary High School','Grade 11'),
  ('100006', (select id from public.schools where code='UMCCC'), 'Farid',   'Aziz',    1350, 1370, 'male',   'member', 'Faculty of Business', 'Accounting'),
  ('100007', (select id from public.schools where code='UMCCC'), 'Grace',   'Wong',    1660, 1690, 'female', 'member', 'Faculty of Science',  'Chemistry'),
  ('100008', (select id from public.schools where code='UMCCC'), 'Hassan',  'Rahim',   1420, 1400, 'male',   'guest',  'King College',       'Grade 12')
on conflict (id) do nothing;

-- One demo tournament (draft, 6 enrolled players, no rounds yet)
insert into public.tournaments (id, school_id, name, format, status, rating_type, is_rated, current_round)
values ('1788230718000', (select id from public.schools where code='UMCCC'), 'UMCCC Rapid Open (Demo)', 'swiss', 'draft', 'rapid', true, 0)
on conflict (id) do nothing;

insert into public.tournament_players (tournament_id, player_id, blitz_rating, rapid_rating)
select '1788230718000', p.id, p.blitz_rating, p.rapid_rating
from public.players p
where p.id in ('100001','100002','100003','100005','100007','100008')
on conflict (tournament_id, player_id) do nothing;

-- ============================================================================
-- 7. VERIFICATION — run these after the script; all should return rows/counts
-- ============================================================================
-- select code from public.schools;                          -- expect: UMCCC
-- select count(*) from public.players;                      -- expect: 8 (demo)
-- select name, format, status from public.tournaments;      -- expect: 1 demo draft
-- select count(*) from public.tournament_players;           -- expect: 6

-- ============================================================================
-- 8. CLEANUP (demo removal — run ONLY when you want the demo data gone)
-- ============================================================================
-- delete from public.tournaments where id = '1788230718000';  -- cascades to tournament_players & matches
-- delete from public.players where id between '100001' and '100008';
-- (keep the schools row — the app needs it)

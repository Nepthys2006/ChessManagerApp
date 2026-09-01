-- Migration 01 — matches composite primary key
-- Resolves the match-id collision found in the Gate 1 review: §5.2 generates
-- per-tournament ids like 'sw_1_0', so two tournaments would collide on the
-- bare text PK and an upsert would cross-update another tournament's match.
-- Model ids stay exactly per §5.2; uniqueness becomes (tournament_id, id).
-- Run in Supabase Dashboard → SQL Editor. Idempotent guard included.

do $$ begin
  if exists (
    select 1 from pg_constraint
    where conname = 'matches_pkey'
      and conrelid = 'public.matches'::regclass
      and pg_get_constraintdef(oid) = 'PRIMARY KEY (id)'
  ) then
    alter table public.matches drop constraint matches_pkey;
    alter table public.matches add primary key (tournament_id, id);
  end if;
end $$;

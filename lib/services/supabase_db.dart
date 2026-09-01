/// Supabase (PostgREST) persistence layer — the online source of truth (§6).
///
/// Key contracts implemented here:
/// - `school_id` is NOT on the models; this layer injects it on every
///   player/team/tournament upsert (§4.1). [init] resolves it from the
///   caller's `profiles` row; [initPublic] resolves it from the `schools`
///   code lookup; [reset] clears the cached value on sign-out.
/// - [loadTournaments] performs the client-side "join" EXACTLY per §6:
///   3 queries (metadata; bulk `tournament_players` via IN; bulk `matches`
///   via IN, ordered by round, board) reassembled in Dart. No SQL joins,
///   CTEs, or RPCs anywhere.
/// - [saveTournament] is the 3-step upsert (metadata → tournament_players →
///   matches), NOT wrapped in a transaction — partial-write risk is accepted
///   per §7.8 and mitigated by the offline queue (§5.6).
/// - Match upserts use the composite-PK conflict target `(tournament_id, id)`
///   per supabase_migration_01_matches_pk.sql.
///
/// Supabase itself is initialized in main.dart (Phase 4) via
/// `Supabase.initialize(url, publishableKey)` from compile-time defines —
/// this file NEVER initializes Supabase and never embeds URL/keys.
library;

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chess_match.dart';
import '../models/player.dart';
import '../models/team.dart';
import '../models/tournament.dart';
import 'local_db.dart';

class SupabaseDb {
  SupabaseDb._();

  /// Caller's tenant, resolved by [init] / [initPublic]. All writes are
  /// rejected while this is null (cannot scope rows without it).
  static String? _schoolId;

  static SupabaseClient get _client => Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Session/tenant resolution (§4.1)
  // ---------------------------------------------------------------------------

  /// Resolves the signed-in caller's `school_id` from their `profiles` row.
  /// Deliberately NOT called inside main()'s login-state logic (§7.10) —
  /// this performs a network round-trip and can fail when offline. Returns
  /// false (never throws) on any failure; sign-out also calls [reset].
  static Future<bool> init() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        _schoolId = null;
        return false;
      }
      final row = await _client
          .from('profiles')
          .select('school_id')
          .eq('id', user.id)
          .single();
      _schoolId = row['school_id'] as String?;
      return _schoolId != null;
    } catch (e) {
      // §7.10: init must be allowed to fail independently of login state.
      _schoolId = null;
      return false;
    }
  }

  /// Resolves the school for the unauthenticated PublicScreen via the
  /// `schools` unique-code lookup (§2, §4.1). Returns false on failure
  /// (e.g. offline); the caller falls back to the local snapshot.
  static Future<bool> initPublic({String schoolCode = 'UMCCC'}) async {
    try {
      final row = await _client
          .from('schools')
          .select('id')
          .eq('code', schoolCode)
          .single();
      _schoolId = row['id'] as String?;
      return _schoolId != null;
    } catch (e) {
      _schoolId = null;
      return false;
    }
  }

  /// Clears the cached school_id (sign-out path, §4.1).
  static void reset() {
    _schoolId = null;
  }

  /// Returns the cached school id, or null (writes are then rejected).
  static String? get schoolId => _schoolId;

  // ---------------------------------------------------------------------------
  // Players
  // ---------------------------------------------------------------------------

  /// Loads the roster; on failure falls back to the LocalDb snapshot (§4.10
  /// offline read fallback). Never throws.
  static Future<List<Player>> loadPlayers() async {
    try {
      final rows = await _client.from('players').select();
      final players = rows.map((row) => Player.fromJson(row)).toList();
      // Fire-and-forget snapshot (§4.10); a failed cache write is harmless
      // (the in-memory list is still returned), so it is explicitly ignored.
      unawaited(LocalDb.savePlayers(players));
      return players;
    } catch (e) {
      // Offline: last snapshot renders instead of an empty screen (§4.10).
      return await LocalDb.loadPlayers() ?? const [];
    }
  }

  /// Upserts players (ids are app-generated upstream via Player.nextId).
  /// Returns false on failure so the caller can queue offline (§4.10).
  static Future<bool> savePlayers(List<Player> players) async {
    final school = _schoolId;
    if (school == null) return false;
    try {
      final rows = [
        for (final p in players) {...p.toJson(), 'school_id': school},
      ];
      await _client.from('players').upsert(rows, onConflict: 'id');
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Convenience single-player upsert (§6).
  static Future<bool> savePlayer(Player player) => savePlayers([player]);

  /// Hard delete (distinct from the is_active soft delete, §7.9).
  /// Returns false on failure.
  static Future<bool> deletePlayer(String id) async {
    try {
      await _client.from('players').delete().eq('id', id);
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Teams
  // ---------------------------------------------------------------------------

  /// Loads saved rosters; falls back to the local snapshot on failure.
  static Future<List<RosterTeam>> loadTeams() async {
    try {
      final rows = await _client.from('teams').select();
      final teams = rows.map((row) => RosterTeam.fromJson(row)).toList();
      // Fire-and-forget snapshot (§4.10) — explicitly ignored on failure.
      unawaited(LocalDb.saveTeams(teams));
      return teams;
    } catch (e) {
      return await LocalDb.loadTeams() ?? const [];
    }
  }

  /// Upserts saved rosters (player_ids jsonb rides along in toJson).
  static Future<bool> saveTeams(List<RosterTeam> teams) async {
    final school = _schoolId;
    if (school == null) return false;
    try {
      final rows = [
        for (final t in teams) {...t.toJson(), 'school_id': school},
      ];
      await _client.from('teams').upsert(rows, onConflict: 'id');
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Hard delete of a saved roster.
  static Future<bool> deleteTeam(String id) async {
    try {
      await _client.from('teams').delete().eq('id', id);
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Tournaments
  // ---------------------------------------------------------------------------

  /// Loads tournaments with the §6 client-side "join":
  /// 1. tournament metadata rows,
  /// 2. bulk `tournament_players` via an IN filter on tournament ids,
  /// 3. bulk `matches` via an IN filter, ordered by round, board.
  /// Falls back to the local snapshot on failure. Never throws.
  static Future<List<Tournament>> loadTournaments(List<Player> players) async {
    try {
      final metaRows = await _client.from('tournaments').select();
      if (metaRows.isEmpty) return const [];
      final ids = metaRows.map((row) => row['id'] as String).toList();

      final rosterRows = await _client
          .from('tournament_players')
          .select()
          .inFilter('tournament_id', ids);
      final matchRows = await _client
          .from('matches')
          .select()
          .inFilter('tournament_id', ids)
          .order('round')
          .order('board');

      // Group bulk rows by tournament id.
      final rosterByTournament = <String, List<Map<String, dynamic>>>{};
      for (final row in rosterRows) {
        final r = row;
        rosterByTournament
            .putIfAbsent(r['tournament_id'] as String, () => [])
            .add(r);
      }
      final matchesByTournament = <String, List<Map<String, dynamic>>>{};
      for (final row in matchRows) {
        final r = row;
        matchesByTournament
            .putIfAbsent(r['tournament_id'] as String, () => [])
            .add(r);
      }

      final masterById = {for (final p in players) p.id: p};
      final tournaments = <Tournament>[];
      for (final row in metaRows) {
        final meta = row;
        // DB rows carry only the §2 columns (no players/rounds json keys);
        // Tournament.fromJson fills those as empty before we reattach them.
        final t = Tournament.fromJson(meta);
        final tid = t.id;

        // Roster: ratings come from the enrollment-time snapshot row (§2
        // tournament_players); names/details from the master roster when
        // available.
        final roster = <Player>[];
        for (final tp in rosterByTournament[tid] ?? const []) {
          final pid = tp['player_id'] as String;
          final blitz = (tp['blitz_rating'] as num?)?.toInt() ?? 1500;
          final rapid = (tp['rapid_rating'] as num?)?.toInt() ?? 1500;
          final master = masterById[pid];
          roster.add(
            master == null
                ? Player(
                    id: pid,
                    firstName: '',
                    lastName: '',
                    blitzRating: blitz,
                    rapidRating: rapid,
                  )
                : master.copyWith(blitzRating: blitz, rapidRating: rapid),
          );
        }
        t.players = roster;

        // Rounds: rows arrive ordered by (round, board); group by the
        // 1-based round number.
        final rounds = <List<ChessMatch>>[];
        for (final m in matchesByTournament[tid] ?? const []) {
          final roundNo = (m['round'] as num?)?.toInt() ?? 0;
          if (roundNo < 1) continue; // Defensive: rounds are 1-based (§2).
          while (rounds.length < roundNo) {
            rounds.add(<ChessMatch>[]);
          }
          rounds[roundNo - 1].add(ChessMatch.fromJson(m));
        }
        t.rounds = rounds;

        tournaments.add(t);
      }
      // Fire-and-forget snapshot (§4.10) — explicitly ignored on failure.
      unawaited(LocalDb.saveTournaments(tournaments));
      return tournaments;
    } catch (e) {
      return await LocalDb.loadTournaments(players) ?? const [];
    }
  }

  /// 3-step save (§6, §7.8): metadata → tournament_players → matches.
  ///
  /// The metadata projection strips the `players`/`rounds` keys that exist on
  /// [Tournament.toJson] purely for offline-queue reconstruction (§5.6) —
  /// they are NOT §2 tournaments columns. Matches upsert on the composite
  /// conflict target `(tournament_id, id)` (supabase_migration_01). Not
  /// transactional — partial-write risk accepted, mitigated by the offline
  /// queue re-sending the whole tournament (§7.8).
  static Future<bool> saveTournament(Tournament tournament) async {
    final school = _schoolId;
    if (school == null) return false;
    try {
      // Step 1 — metadata (project out non-column keys, inject school_id).
      final meta = tournament.toJson()
        ..remove('players')
        ..remove('rounds');
      meta['school_id'] = school;
      await _client.from('tournaments').upsert(meta, onConflict: 'id');

      // Step 2 — roster at enrollment-time ratings (§2 tournament_players).
      final rosterRows = [
        for (final p in tournament.players)
          <String, dynamic>{
            'tournament_id': tournament.id,
            'player_id': p.id,
            'blitz_rating': p.blitzRating,
            'rapid_rating': p.rapidRating,
          },
      ];
      if (rosterRows.isNotEmpty) {
        await _client
            .from('tournament_players')
            .upsert(rosterRows, onConflict: 'tournament_id,player_id');
      }

      // Step 3 — matches, composite PK (tournament_id, id).
      final matchRows = [
        for (final round in tournament.rounds)
          for (final m in round)
            {...m.toJson(), 'tournament_id': tournament.id},
      ];
      if (matchRows.isNotEmpty) {
        await _client
            .from('matches')
            .upsert(matchRows, onConflict: 'tournament_id,id');
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Saves every tournament; stops at the first failure and reports false so
  /// the caller can queue the remainder offline (§4.10).
  static Future<bool> saveTournaments(List<Tournament> tournaments) async {
    for (final t in tournaments) {
      if (!await saveTournament(t)) return false;
    }
    return true;
  }

  /// Hard delete of the metadata row only — the DB cascades to
  /// tournament_players and matches (§2 ON DELETE CASCADE).
  static Future<bool> deleteTournament(String id) async {
    try {
      await _client.from('tournaments').delete().eq('id', id);
      return true;
    } catch (e) {
      return false;
    }
  }
}

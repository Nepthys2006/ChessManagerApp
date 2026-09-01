/// Local snapshot cache backed by `shared_preferences` (§1, §6).
///
/// Mirrors [SupabaseDb]'s load/save surface. The shell fires-and-forgets a
/// snapshot after every successful Supabase load (§4.10) so the offline read
/// fallback can render the last known state. Tournaments are stored as their
/// FULL `toJson()` (including players/rounds) so a queued/snapshotted
/// tournament is reconstructable from a single entry (§5.6).
///
/// Load methods return `null` on failure (distinct from a legitimately empty
/// snapshot) so [MigrationService] can abort on a broken snapshot while other
/// callers treat null as "nothing available".
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/player.dart';
import '../models/team.dart';
import '../models/tournament.dart';
import 'db_constants.dart';

class LocalDb {
  LocalDb._();

  // ---------------------------------------------------------------------------
  // Players
  // ---------------------------------------------------------------------------

  /// Loads the roster snapshot; null on read/decode failure.
  static Future<List<Player>?> loadPlayers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(DbKeys.players);
      if (raw == null) return const [];
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => Player.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // Corrupt snapshot: report failure rather than silently returning [].
      return null;
    }
  }

  /// Upsert-by-id snapshot write. Returns false on storage failure.
  static Future<bool> savePlayers(List<Player> players) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadPlayers() ?? const <Player>[];
      final merged = _upsertById<Player>(existing, players, (p) => p.id);
      await prefs.setString(
        DbKeys.players,
        jsonEncode(merged.map((p) => p.toJson()).toList()),
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Teams
  // ---------------------------------------------------------------------------

  /// Loads the saved-roster snapshot; null on read/decode failure.
  static Future<List<RosterTeam>?> loadTeams() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(DbKeys.teams);
      if (raw == null) return const [];
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => RosterTeam.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  /// REPLACE-ALL snapshot write (delete-missing): removes local rows absent
  /// from [teams]. Used after successful remote fetches so hard-deleted teams
  /// cannot resurrect from a stale snapshot. Players keep merge semantics
  /// (soft delete via is_active). Returns false on storage failure.
  static Future<bool> replaceAllTeams(List<RosterTeam> teams) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        DbKeys.teams,
        jsonEncode(teams.map((t) => t.toJson()).toList()),
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Upsert-by-id snapshot write. Returns false on storage failure.
  static Future<bool> saveTeams(List<RosterTeam> teams) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadTeams() ?? const <RosterTeam>[];
      final merged = _upsertById<RosterTeam>(existing, teams, (t) => t.id);
      await prefs.setString(
        DbKeys.teams,
        jsonEncode(merged.map((t) => t.toJson()).toList()),
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Removes a saved roster from the local snapshot.
  static Future<bool> deleteTeam(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadTeams() ?? const <RosterTeam>[];
      final kept = existing.where((t) => t.id != id).toList();
      await prefs.setString(
        DbKeys.teams,
        jsonEncode(kept.map((t) => t.toJson()).toList()),
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Tournaments
  // ---------------------------------------------------------------------------

  /// Loads the tournaments snapshot (full objects incl. players/rounds).
  /// The [players] argument exists for signature parity with
  /// [SupabaseDb.loadTournaments]; the snapshot is self-contained, so it is
  /// unused here.
  static Future<List<Tournament>?> loadTournaments(List<Player> players) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(DbKeys.tournaments);
      if (raw == null) return const [];
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => Tournament.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  /// Upsert-by-id snapshot write. Returns false on storage failure.
  static Future<bool> saveTournament(Tournament tournament) =>
      saveTournaments([tournament]);

  /// REPLACE-ALL snapshot write (delete-missing): removes local rows absent
  /// from [tournaments]. Used after successful remote fetches so hard-deleted
  /// tournaments cannot resurrect from a stale snapshot. Returns false on
  /// storage failure.
  static Future<bool> replaceAllTournaments(
    List<Tournament> tournaments,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        DbKeys.tournaments,
        jsonEncode(tournaments.map((t) => t.toJson()).toList()),
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Upsert-by-id snapshot write. Returns false on storage failure.
  static Future<bool> saveTournaments(List<Tournament> tournaments) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadTournaments(const []) ?? const <Tournament>[];
      final merged = _upsertById<Tournament>(
        existing,
        tournaments,
        (t) => t.id,
      );
      await prefs.setString(
        DbKeys.tournaments,
        jsonEncode(merged.map((t) => t.toJson()).toList()),
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Removes a tournament from the local snapshot.
  static Future<bool> deleteTournament(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadTournaments(const []) ?? const <Tournament>[];
      final kept = existing.where((t) => t.id != id).toList();
      await prefs.setString(
        DbKeys.tournaments,
        jsonEncode(kept.map((t) => t.toJson()).toList()),
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Dev helper
  // ---------------------------------------------------------------------------

  /// Clears ALL local snapshot keys (dev/testing helper, §6).
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(DbKeys.players);
    await prefs.remove(DbKeys.tournaments);
    await prefs.remove(DbKeys.teams);
    await prefs.remove(DbKeys.pendingTournamentFinalizations);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Merge-by-id upsert: replaces existing entries with matching ids, appends
  /// the rest, preserving original ordering otherwise (§7.12 — full replace,
  /// never a blind addAll on top).
  static List<T> _upsertById<T>(
    List<T> existing,
    List<T> updates,
    String Function(T) idOf,
  ) {
    final byId = <String, T>{for (final item in existing) idOf(item): item};
    for (final item in updates) {
      byId[idOf(item)] = item;
    }
    return byId.values.toList();
  }
}

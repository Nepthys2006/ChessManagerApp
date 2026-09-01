/// Offline write queue (§5.6, §4.10) backed by `shared_preferences`.
///
/// Queued entries live under the exact key `pending_tournament_finalizations_v1`
/// (§3). Queuing a tournament stores its FULL roster so the entry is
/// reconstructable on its own (§5.6). Re-queuing the same tournament id
/// REPLACES the earlier entry — no duplicate growth. Draining is triggered by
/// the shell on authenticated launch and via a manual "Sync Now" button
/// (§4.10); failed entries stay queued for the next attempt — deliberately NO
/// exponential backoff (§4.13).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/player.dart';
import '../models/tournament.dart';
import 'db_constants.dart';

class PendingSyncService {
  PendingSyncService._();

  /// Decodes the raw JSON entry list; empty on any failure (a corrupt queue
  /// must not crash the app — explicit best-effort decision, §10.4).
  static Future<List<Map<String, dynamic>>> _loadEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(DbKeys.pendingTournamentFinalizations);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => e as Map<String, dynamic>)
          .toList();
    } catch (e) {
      // Corrupt queue payload: start from an empty queue rather than crash.
      return [];
    }
  }

  static Future<void> _writeEntries(List<Map<String, dynamic>> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      DbKeys.pendingTournamentFinalizations,
      jsonEncode(entries),
    );
  }

  /// Queues [players] and, optionally, [tournament] for later sync (§5.6).
  /// When [tournament] is given, any existing entry with the same
  /// tournament.id is REMOVED first (replace, not append — no dupes).
  static Future<void> queue({
    required List<Player> players,
    Tournament? tournament,
  }) async {
    final entries = await _loadEntries();
    if (tournament != null) {
      entries.removeWhere(
        (e) =>
            (e['tournament'] as Map<String, dynamic>?)?['id'] == tournament.id,
      );
    }
    entries.add(<String, dynamic>{
      'tournament': tournament?.toJson(),
      'players': players.map((p) => p.toJson()).toList(),
    });
    await _writeEntries(entries);
  }

  /// Number of queued entries awaiting sync.
  static Future<int> pendingCount() async => (await _loadEntries()).length;

  /// Attempts to drain the queue (§5.6):
  /// - each entry: save its players, then its tournament (if present);
  /// - per-entry failure (callback returns false OR throws) keeps that entry
  ///   queued and continues with the rest — no abort, no backoff;
  /// - returns the number of successfully synced entries.
  static Future<int> trySyncAll({
    required Future<bool> Function(Tournament tournament) saveTournament,
    required Future<bool> Function(List<Player> players) savePlayers,
  }) async {
    final entries = await _loadEntries();
    if (entries.isEmpty) return 0;
    final remaining = <Map<String, dynamic>>[];
    var synced = 0;
    for (final entry in entries) {
      try {
        final queuedPlayers = (entry['players'] as List<dynamic>? ?? const [])
            .map((p) => Player.fromJson(p as Map<String, dynamic>))
            .toList();
        var ok = await savePlayers(queuedPlayers);
        final tournamentJson = entry['tournament'] as Map<String, dynamic>?;
        if (ok && tournamentJson != null) {
          ok = await saveTournament(Tournament.fromJson(tournamentJson));
        }
        if (ok) {
          synced += 1;
        } else {
          remaining.add(entry); // stays queued for the next attempt (§4.10)
        }
      } catch (e) {
        // Per-entry catch (§5.6): one bad entry never blocks the rest.
        remaining.add(entry);
      }
    }
    await _writeEntries(remaining);
    return synced;
  }
}

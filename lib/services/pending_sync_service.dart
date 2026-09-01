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

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/player.dart';
import '../models/tournament.dart';
import 'db_constants.dart';

class PendingSyncService {
  PendingSyncService._();

  /// Result of loading the queue: the salvaged entries, plus whether the raw
  /// stored payload failed to parse entirely (`loadFailed == true`).
  static Future<({List<Map<String, dynamic>> entries, bool loadFailed})>
  _loadEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(DbKeys.pendingTournamentFinalizations);
    if (raw == null) {
      return (entries: <Map<String, dynamic>>[], loadFailed: false);
    }
    List<dynamic>? decoded;
    try {
      decoded = jsonDecode(raw) as List<dynamic>;
    } catch (e) {
      // Entire payload unparsable: do NOT overwrite it — the next write
      // against this key would destroy every pending finalization. Treat the
      // queue as load-failed and leave the stored value untouched.
      assert(() {
        debugPrint('PendingSyncService: corrupt queue payload; load failed');
        return true;
      }());
      final empty = <Map<String, dynamic>>[];
      return (entries: empty, loadFailed: true);
    }
    // Salvage per entry: keep only well-shaped maps; drop genuinely corrupt
    // entries so one bad element can't destroy the whole queue (M1).
    final salvaged = <Map<String, dynamic>>[];
    for (final e in decoded) {
      if (e is Map && e['players'] is List && e['tournament'] is Map?) {
        salvaged.add(Map<String, dynamic>.from(e));
      }
    }
    return (entries: salvaged, loadFailed: false);
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
  ///
  /// Throws [StateError] if the stored queue is corrupt (load-failed): the
  /// caller must not silently lose the queued finalizations, so we refuse to
  /// overwrite instead of wiping the key.
  static Future<void> queue({
    required List<Player> players,
    Tournament? tournament,
  }) async {
    final (:entries, loadFailed: failed) = await _loadEntries();
    if (failed) {
      throw StateError('pending sync queue corrupt; refusing to overwrite');
    }
    if (tournament != null) {
      entries.removeWhere((e) {
        final t = e['tournament'];
        return t is Map && t['id'] == tournament.id;
      });
    }
    entries.add(<String, dynamic>{
      'tournament': tournament?.toJson(),
      'players': players.map((p) => p.toJson()).toList(),
    });
    await _writeEntries(entries);
  }

  /// Number of queued entries awaiting sync. 0 when the queue is empty or
  /// load-failed (the stored payload is left untouched in the latter case).
  static Future<int> pendingCount() async {
    final (:entries, loadFailed: _) = await _loadEntries();
    return entries.length;
  }

  /// Attempts to drain the queue (§5.6):
  /// - each entry: save its players, then its tournament (if present);
  /// - per-entry failure (callback returns false OR throws) keeps that entry
  ///   queued and continues with the rest — no abort, no backoff;
  /// - returns the number of successfully synced entries.
  /// A corrupt (unparsable) stored payload is treated as load-failed: the
  /// queue is left untouched and 0 is returned.
  static Future<int> trySyncAll({
    required Future<bool> Function(Tournament tournament) saveTournament,
    required Future<bool> Function(List<Player> players) savePlayers,
  }) async {
    final (:entries, loadFailed: failed) = await _loadEntries();
    if (failed || entries.isEmpty) return 0;
    final remaining = <Map<String, dynamic>>[];
    var synced = 0;
    for (final entry in entries) {
      try {
        final queuedPlayers = (entry['players'] as List<dynamic>? ?? const [])
            .map((p) => Player.fromJson(p as Map<String, dynamic>))
            .toList();
        var ok = await savePlayers(queuedPlayers);
        final tournamentJson = entry['tournament'] as Map?;
        if (ok && tournamentJson != null) {
          ok = await saveTournament(
            Tournament.fromJson(Map<String, dynamic>.from(tournamentJson)),
          );
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

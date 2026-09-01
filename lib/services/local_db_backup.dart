/// JSON file backup/restore to the platform documents directory (§5.7).
///
/// Backup files are named `chess_backup_<ISO8601-with-":"-and-"."-replaced-
/// by-"-">.json` (§3, §7.3 — a manual string replace, not a general
/// sanitizer). Payload schema: `{version: 1, created_at, players,
/// tournaments}`. Restore is UPSERT ONLY — it never deletes anything not
/// present in the file (§4.11).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/player.dart';
import '../models/tournament.dart';
import 'db_constants.dart';
import 'local_db.dart';

class LocalDbBackup {
  LocalDbBackup._();

  /// Writes the current LocalDb snapshot (players + tournaments) to a new
  /// timestamped JSON file in the documents directory. Returns the written
  /// file, or null on failure (best-effort, never throws to the caller).
  static Future<File?> backup() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final players = await LocalDb.loadPlayers() ?? const <Player>[];
      final tournaments =
          await LocalDb.loadTournaments(const []) ?? const <Tournament>[];
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final file = File(
        '${dir.path}${Platform.pathSeparator}$backupFilePrefix$timestamp.json',
      );
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'version': backupSchemaVersion,
          'created_at': DateTime.now().toIso8601String(),
          'players': players.map((p) => p.toJson()).toList(),
          'tournaments': tournaments.map((t) => t.toJson()).toList(),
        }),
      );
      return file;
    } catch (e) {
      return null; // Best-effort backup: surface null, never throw (§10.4).
    }
  }

  /// Lists backup candidates in the documents directory. Loose contract
  /// (§7.4): ANY filename containing `chess_backup_` counts. Returns an
  /// empty list if the directory doesn't exist yet (no crash, §4.11).
  static Future<List<File>> listBackups() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!dir.existsSync()) return const [];
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.contains(backupFilePrefix))
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path)); // newest first
      return files;
    } catch (e) {
      return const []; // Listing is best-effort; empty on failure (§4.11).
    }
  }

  /// Restores a backup file (§5.7): rejects any payload whose version is not
  /// 1 by THROWING `Unrecognised backup version`; otherwise upserts players
  /// then tournaments via the injected callbacks — UPSERT ONLY, never
  /// deletes. Returns the restored records for the caller's in-memory merge,
  /// or null if a save callback reported failure.
  static Future<({List<Player> players, List<Tournament> tournaments})?>
  restore(
    File file, {
    required Future<bool> Function(List<Player> players) savePlayers,
    required Future<bool> Function(List<Tournament> tournaments)
    saveTournaments,
  }) async {
    final payload =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (payload['version'] != backupSchemaVersion) {
      throw StateError('Unrecognised backup version');
    }
    final players = (payload['players'] as List<dynamic>? ?? const [])
        .map((p) => Player.fromJson(p as Map<String, dynamic>))
        .toList();
    final tournaments = (payload['tournaments'] as List<dynamic>? ?? const [])
        .map((t) => Tournament.fromJson(t as Map<String, dynamic>))
        .toList();
    final playersOk = await savePlayers(players);
    final tournamentsOk = await saveTournaments(tournaments);
    if (!playersOk || !tournamentsOk) return null;
    return (players: players, tournaments: tournaments);
  }

  /// Deletes a backup file. Returns false on failure.
  static Future<bool> delete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}

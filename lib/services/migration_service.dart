/// One-time legacy local-storage → Supabase migration (§5.7, §4.11).
///
/// Idempotent: everything is pushed via upsert, so a partially failed run is
/// safe to re-run. Players are ALWAYS migrated before tournaments (tournaments
/// reference player ids), in batches of [migrationBatchSize] (§3, §10.3).
/// Per-item errors are collected without aborting the run; progress is
/// reported via the [MigrationService.migrate] callback and total elapsed
/// time is returned with the result.
library;

import 'db_constants.dart';

import 'local_db.dart';
import 'supabase_db.dart';

/// Result of a [MigrationService.migrate] run (§5.7 return shape).
///
/// Two public declarations in one file is deliberate (§10.1 precedent, same
/// as team.dart): the result type has no meaning outside its service.
class MigrationResult {
  const MigrationResult({
    required this.playersMigrated,
    required this.tournamentsMigrated,
    required this.matchesMigrated,
    required this.errors,
    required this.elapsedTime,
  });

  final int playersMigrated;
  final int tournamentsMigrated;
  final int matchesMigrated;
  final List<String> errors;
  final Duration elapsedTime;
}

class MigrationService {
  MigrationService._();

  /// Runs the idempotent local→Supabase push (§5.7). Progress messages go to
  /// [onProgress] when provided. Never throws — every failure is collected
  /// in [MigrationResult.errors].
  static Future<MigrationResult> migrate({
    void Function(String message)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    final errors = <String>[];
    var playersMigrated = 0;
    var tournamentsMigrated = 0;
    var matchesMigrated = 0;

    onProgress?.call('Loading local players...');
    final players = await LocalDb.loadPlayers();
    if (players == null) {
      // Hard failure: cannot proceed at all without the roster snapshot.
      errors.add(
        'Failed to load the local players snapshot — migration aborted',
      );
      return MigrationResult(
        playersMigrated: 0,
        tournamentsMigrated: 0,
        matchesMigrated: 0,
        errors: errors,
        elapsedTime: DateTime.now().difference(startedAt),
      );
    }

    // Players first, in batches of [migrationBatchSize] (§5.7).
    for (var i = 0; i < players.length; i += migrationBatchSize) {
      final end = (i + migrationBatchSize).clamp(0, players.length);
      final batch = players.sublist(i, end);
      onProgress?.call(
        'Migrating players ${i + 1}–$end of ${players.length}...',
      );
      try {
        final ok = await SupabaseDb.savePlayers(batch);
        if (ok) {
          playersMigrated += batch.length;
        } else {
          errors.add('Player batch starting at index $i failed to upsert');
        }
      } catch (e) {
        errors.add('Player batch starting at index $i: $e');
      }
    }

    onProgress?.call('Loading local tournaments...');
    final tournaments = await LocalDb.loadTournaments(players);
    if (tournaments == null) {
      // Recorded, not fatal: players were still migrated (§5.7).
      errors.add('Failed to load the local tournaments snapshot');
    } else {
      for (final t in tournaments) {
        onProgress?.call('Migrating tournament "${t.name}"...');
        final matchCount = t.rounds.fold<int>(0, (n, r) => n + r.length);
        try {
          final ok = await SupabaseDb.saveTournament(t);
          if (ok) {
            tournamentsMigrated += 1;
            matchesMigrated += matchCount;
          } else {
            errors.add('Tournament ${t.id} (${t.name}) failed to save');
          }
        } catch (e) {
          errors.add('Tournament ${t.id} (${t.name}): $e');
        }
      }
    }

    onProgress?.call(
      'Migration finished: $playersMigrated players, '
      '$tournamentsMigrated tournaments, $matchesMigrated matches.',
    );
    return MigrationResult(
      playersMigrated: playersMigrated,
      tournamentsMigrated: tournamentsMigrated,
      matchesMigrated: matchesMigrated,
      errors: errors,
      elapsedTime: DateTime.now().difference(startedAt),
    );
  }
}

/// Shared persistence constants (§3, §10.3) — collected in one place rather
/// than scattering bare string/numeric literals through the service layer.
library;

/// Hard-coded `shared_preferences` keys (§3 — exact values, do not rename).
class DbKeys {
  DbKeys._();

  /// Local roster snapshot cache.
  static const String players = 'chess_players_v1';

  /// Local tournaments snapshot cache (full toJson, incl. players/rounds).
  static const String tournaments = 'chess_tournaments_v1';

  /// Local saved-roster snapshot cache.
  static const String teams = 'chess_teams_v1';

  /// Offline write queue (§5.6).
  static const String pendingTournamentFinalizations =
      'pending_tournament_finalizations_v1';
}

/// Players per upsert batch during legacy migration (§3, §5.7).
const int migrationBatchSize = 50;

/// Backup filename prefix (§3, §5.7). ANY filename containing this is treated
/// as a backup candidate by [LocalDbBackup.listBackups] — a loose contract.
const String backupFilePrefix = 'chess_backup_';

/// Backup JSON schema version (§3, §5.7). Restore rejects anything else.
const int backupSchemaVersion = 1;

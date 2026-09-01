/// Offline sync queue tests (§8): enqueue, dedupe-by-tournament-id (re-queue
/// replaces), drain success removes the entry, drain failure keeps it queued,
/// and full-roster reconstruction from a queued tournament entry (§5.6).
library;

import 'package:chess_manager/models/chess_match.dart';
import 'package:chess_manager/models/player.dart';
import 'package:chess_manager/models/tournament.dart';
import 'package:chess_manager/services/pending_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Player p(String id) => Player(id: id, firstName: 'F$id', lastName: 'L$id');

  Tournament t(String id, {List<Player>? players}) {
    final tournament = Tournament(
      id: id,
      name: 'T$id',
      players: players ?? [p('1'), p('2')],
    );
    tournament.rounds.add([
      ChessMatch(
        id: 'sw_1_0',
        round: 1,
        board: 0,
        whitePlayerId: '1',
        blackPlayerId: '2',
        result: MatchResult.draw,
      ),
    ]);
    return tournament;
  }

  test('enqueue players only grows pendingCount', () async {
    await PendingSyncService.queue(players: [p('1')]);
    expect(await PendingSyncService.pendingCount(), 1);
  });

  test(
    're-queuing the same tournament id REPLACES the earlier entry',
    () async {
      await PendingSyncService.queue(players: [p('1')], tournament: t('tt'));
      await PendingSyncService.queue(
        players: [p('1'), p('2'), p('3')],
        tournament: t('tt'),
      );
      expect(await PendingSyncService.pendingCount(), 1);

      // Drain and confirm the queued entry is the LATEST one (3 players).
      var seenPlayers = <Player>[];
      final synced = await PendingSyncService.trySyncAll(
        saveTournament: (_) async => true,
        savePlayers: (players) async {
          seenPlayers = players;
          return true;
        },
      );
      expect(synced, 1);
      expect(seenPlayers.length, 3);
      expect(await PendingSyncService.pendingCount(), 0);
    },
  );

  test('drain success removes the entry', () async {
    await PendingSyncService.queue(players: [p('1')]);
    final synced = await PendingSyncService.trySyncAll(
      saveTournament: (_) async => true,
      savePlayers: (_) async => true,
    );
    expect(synced, 1);
    expect(await PendingSyncService.pendingCount(), 0);
  });

  test(
    'drain failure (callback returns false) keeps the entry queued',
    () async {
      await PendingSyncService.queue(players: [p('1')]);
      final synced = await PendingSyncService.trySyncAll(
        saveTournament: (_) async => true,
        savePlayers: (_) async => false,
      );
      expect(synced, 0);
      expect(await PendingSyncService.pendingCount(), 1);
    },
  );

  test(
    'drain failure (callback throws) keeps only the failing entry queued',
    () async {
      await PendingSyncService.queue(players: [p('1')], tournament: t('ok'));
      await PendingSyncService.queue(players: [p('9')], tournament: t('bad'));
      var first = true;
      final synced = await PendingSyncService.trySyncAll(
        saveTournament: (tournament) async {
          if (tournament.id == 'bad') throw StateError('network down');
          return true;
        },
        savePlayers: (players) async {
          final ok = first;
          first = false;
          return ok;
        },
      );
      expect(synced, 1);
      expect(await PendingSyncService.pendingCount(), 1);
    },
  );

  test('full-roster reconstruction from a queued tournament entry', () async {
    final roster = [
      p('1').copyWith(blitzRating: 1700, rapidRating: 1650),
      p('2').copyWith(blitzRating: 1600, rapidRating: 1550),
    ];
    final original = Tournament(
      id: 'tt99',
      name: 'Reconstruction Cup',
      players: roster,
    );
    original.rounds.add([
      ChessMatch(
        id: 'sw_1_0',
        round: 1,
        board: 0,
        whitePlayerId: '1',
        blackPlayerId: '2',
        result: MatchResult.whiteWins,
        whiteRatingDelta: 9,
        blackRatingDelta: -9,
      ),
    ]);
    await PendingSyncService.queue(players: roster, tournament: original);

    Tournament? rebuilt;
    List<Player>? savedPlayers;
    final synced = await PendingSyncService.trySyncAll(
      saveTournament: (tournament) async {
        rebuilt = tournament;
        return true;
      },
      savePlayers: (players) async {
        savedPlayers = players;
        return true;
      },
    );

    expect(synced, 1);
    // Players round-trip through the queue with full fidelity.
    expect(savedPlayers!.length, 2);
    expect(savedPlayers![0].id, '1');
    expect(savedPlayers![0].rapidRating, 1650);
    // The tournament is fully reconstructable from the single queue entry:
    // roster AND rounds (§5.6 — no separate storage needed).
    expect(rebuilt!.id, 'tt99');
    expect(rebuilt!.name, 'Reconstruction Cup');
    expect(rebuilt!.players.length, 2);
    expect(rebuilt!.players[1].blitzRating, 1600);
    expect(rebuilt!.rounds.length, 1);
    expect(rebuilt!.rounds[0].length, 1);
    expect(rebuilt!.rounds[0][0].result, MatchResult.whiteWins);
    expect(rebuilt!.rounds[0][0].whiteRatingDelta, 9);
  });
}

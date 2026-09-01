import 'package:flutter_test/flutter_test.dart';

import 'package:chess_manager/models/bracket_generator.dart';
import 'package:chess_manager/models/chess_match.dart';
import 'package:chess_manager/models/player.dart';
import 'package:chess_manager/models/team.dart';
import 'package:chess_manager/models/tournament.dart';

Tournament _teamTournament({
  required List<RosterTeam> teams,
  required List<Player> players,
  int maxBoards = 2,
}) => Tournament(
  id: '1',
  name: 'Team Cup',
  format: TournamentFormat.swiss,
  ratingType: RatingType.blitz,
  maxBoards: maxBoards,
  teams: teams,
  players: players,
);

// 4 teams of 2 board players each; ids T{i} with players 1000{i}1/1000{i}2.
const _teamDefs = {
  'T1': ['100001', '100002'],
  'T2': ['100003', '100004'],
  'T3': ['100005', '100006'],
  'T4': ['100007', '100008'],
};

Tournament _fourTeamCup() {
  final teams = [
    for (final e in _teamDefs.entries)
      RosterTeam(id: e.key, name: e.key, playerIds: e.value),
  ];
  final players = [
    // Board-1 players get descending ratings so round-1 ordering is stable.
    Player(id: '100001', firstName: 'a', lastName: 'a', blitzRating: 1800),
    Player(id: '100002', firstName: 'a', lastName: 'a', blitzRating: 1700),
    Player(id: '100003', firstName: 'a', lastName: 'a', blitzRating: 1600),
    Player(id: '100004', firstName: 'a', lastName: 'a', blitzRating: 1500),
    Player(id: '100005', firstName: 'a', lastName: 'a', blitzRating: 1400),
    Player(id: '100006', firstName: 'a', lastName: 'a', blitzRating: 1300),
    Player(id: '100007', firstName: 'a', lastName: 'a', blitzRating: 1200),
    Player(id: '100008', firstName: 'a', lastName: 'a', blitzRating: 1100),
  ];
  return _teamTournament(teams: teams, players: players);
}

void main() {
  group('Team Swiss round 1 (§5.2)', () {
    test('top half vs bottom half, top-half team white', () {
      final t = _fourTeamCup();
      final matches = t.generateNextRound();
      expect(t.teamPairings.length, 1);
      final pairings = t.teamPairings.single;
      expect(pairings.length, 2);
      // Teams sorted by avg board rating: T1 (1750), T2 (1550), T3 (1350),
      // T4 (1150). Top half: T1, T2 (white); bottom half: T3, T4.
      expect(pairings[0].whiteTeamId, 'T1');
      expect(pairings[0].blackTeamId, 'T3');
      expect(pairings[1].whiteTeamId, 'T2');
      expect(pairings[1].blackTeamId, 'T4');
      expect(matches.length, 4); // 2 pairings x 2 boards
      for (final m in matches) {
        expect(m.id, startsWith('tsw_1_'));
        expect(m.isBye, isFalse);
      }
    });

    test('Olympiad color flip: even board indexes flip to the black team', () {
      final t = _fourTeamCup();
      t.generateNextRound();
      final pairing = t.teamPairings.single.first; // T1 (white) vs T3
      // Board 0 (board 1, odd): T1's player is White.
      expect(pairing.whiteBoardSlots[0], '100001');
      // Board 1 (even, FLIPPED): T3's board-2 player (100006) is White.
      final m1 = t.rounds.single.firstWhere((m) => m.board == 1);
      expect({m1.whitePlayerId, m1.blackPlayerId}, {'100002', '100006'});
      expect(m1.whitePlayerId, '100006'); // black team's player is White
    });

    test('forfeited board: single-present board -> individual bye', () {
      final teams = [
        RosterTeam(id: 'TA', name: 'A', playerIds: ['100001', '100002']),
        RosterTeam(id: 'TB', name: 'B', playerIds: ['100003']),
      ];
      final players = [
        Player(id: '100001', firstName: 'a', lastName: 'a', blitzRating: 1800),
        Player(id: '100002', firstName: 'a', lastName: 'a', blitzRating: 1700),
        Player(id: '100003', firstName: 'a', lastName: 'a', blitzRating: 1600),
      ];
      final t = _teamTournament(teams: teams, players: players);
      final matches = t.generateNextRound();
      // Board 0: 100001 vs 100003; board 1: 100002 (TA) vs empty -> forfeited
      // board -> individual bye for the white team's player.
      expect(matches.length, 2);
      final forfeit = matches.firstWhere((m) => m.isBye);
      expect(forfeit.whitePlayerId, '100002');
      final pairing = t.teamPairings.single.single;
      expect(pairing.whiteBoardSlots, ['100001', '100002']);
      expect(pairing.blackBoardSlots, ['100003', null]);
      // matchIds: null ONLY where both slots are null — no such board here.
      expect(pairing.matchIds[1], isNotNull);
      expect(pairing.matchIds[0], isNotNull);
    });

    test('odd team count: last team bye + individual byes for its players', () {
      final teams = [
        for (final e in _teamDefs.entries.take(3))
          RosterTeam(id: e.key, name: e.key, playerIds: e.value),
      ];
      final players = [
        for (var i = 1; i <= 6; i++)
          Player(
            id: '10000$i',
            firstName: 'a',
            lastName: 'a',
            blitzRating: 2000 - i * 100,
          ),
      ];
      final t = _teamTournament(teams: teams, players: players);
      final matches = t.generateNextRound();
      final pairings = t.teamPairings.single;
      expect(pairings.length, 2); // 1 pairing + 1 team bye
      final byePairing = pairings.firstWhere((p) => p.blackTeamId == null);
      expect(byePairing.whiteTeamId, 'T3'); // lowest average rating
      // Every present player on the bye team gets an individual bye.
      final byePlayers = matches
          .where((m) => m.isBye)
          .map((m) => m.whitePlayerId)
          .toSet();
      expect(byePlayers, {'100005', '100006'});
      // matchIds non-null wherever a slot is present, even for byes.
      expect(byePairing.matchIds.every((id) => id != null), isTrue);
    });
  });

  group('Team standings (§5.3)', () {
    test('board points, match points, buchholz, sort order', () {
      final t = _fourTeamCup();
      t.generateNextRound();
      // Round 1: T1 (white) vs T3, T2 (white) vs T4.
      // Board 0: T1's 100001 white vs T3's 100005 -> white wins (+1 T1).
      // Board 1 (flipped): T3's 100006 white vs T1's 100002 -> white wins
      // (+1 T3). So T1 vs T3: 1 - 1 -> 0.5 match points each.
      final round1 = t.rounds.single;
      for (final m in round1) {
        m.result = MatchResult.whiteWins;
      }
      t.generateNextRound();
      final round2 = t.rounds[1];
      for (final m in round2) {
        m.result = MatchResult.blackWins;
      }
      final standings = t.teamStandings();
      // Each round: every board a win on alternating flips -> each team wins
      // exactly one board per pairing -> 1-1 -> 0.5 match points, 1 board
      // point per round. Over 2 rounds: 1.0 match points, 2 board points,
      // 2 draws.
      for (final s in standings) {
        expect(s.matchPoints, 1.0);
        expect(s.matchWins, 0);
        expect(s.matchDraws, 2);
        expect(s.matchLosses, 0);
        expect(s.boardPoints, 2);
      }
      // Team Buchholz: each of the 2 faced opponents has 1.0 final match
      // points.
      for (final s in standings) {
        expect(s.teamBuchholz, 2.0);
      }
      // Equal on all numeric tiebreaks -> sorted by team name ascending.
      expect(standings.map((s) => s.team.name).toList(), [
        'T1',
        'T2',
        'T3',
        'T4',
      ]);
    });

    test('team bye: +1 match point and +1 win, board points untouched', () {
      final teams = [
        for (final e in _teamDefs.entries.take(3))
          RosterTeam(id: e.key, name: e.key, playerIds: e.value),
      ];
      final players = [
        for (var i = 1; i <= 6; i++)
          Player(
            id: '10000$i',
            firstName: 'a',
            lastName: 'a',
            blitzRating: 2000 - i * 100,
          ),
      ];
      final t = _teamTournament(teams: teams, players: players);
      t.generateNextRound();
      for (final m in t.rounds.single) {
        if (!m.isBye) m.result = MatchResult.whiteWins;
      }
      final standings = t.teamStandings();
      final byeRow = standings.firstWhere((s) => s.team.id == 'T3');
      expect(byeRow.matchPoints, 1);
      expect(byeRow.matchWins, 1);
      expect(byeRow.boardPoints, 0); // board points untouched by a team bye
      expect(byeRow.teamBuchholz, 0); // no opponent faced
      // The two paired teams split 1-1 (flipped colors, both white wins):
      // 0.5 match points and 1 board point each.
      final t1 = standings.firstWhere((s) => s.team.id == 'T1');
      expect(t1.matchPoints, 0.5);
      expect(t1.boardPoints, 1);
    });
  });

  group('Team Swiss later rounds (§5.2)', () {
    test('rematch avoidance at team granularity', () {
      final t = _fourTeamCup();
      for (var r = 0; r < 3; r++) {
        final matches = t.generateNextRound();
        final seen = <String>{};
        for (final pairing in t.teamPairings.last) {
          if (pairing.blackTeamId == null) continue;
          final key = [pairing.whiteTeamId, pairing.blackTeamId]..sort();
          final added = seen.add(key.join('-'));
          expect(added, isTrue, reason: 'team rematch in round ${r + 1}');
        }
        for (final m in matches) {
          if (!m.isBye) m.result = MatchResult.whiteWins;
        }
      }
    });

    test('allTeamPairsPlayed and teamBoardSlots', () {
      final t = _fourTeamCup();
      expect(t.allTeamPairsPlayed, isFalse);
      final slots = BracketGenerator.teamBoardSlots(t.teams.first, 4);
      expect(slots, ['100001', '100002', null, null]);
      // Play out the full round robin (3 rounds for 4 teams).
      for (var r = 0; r < 3; r++) {
        t.generateNextRound();
        for (final m in t.rounds.last) {
          if (!m.isBye) m.result = MatchResult.whiteWins;
        }
      }
      expect(t.allTeamPairsPlayed, isTrue);
    });
  });
}

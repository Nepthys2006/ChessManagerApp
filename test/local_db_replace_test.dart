/// LocalDb replace-all snapshot writes (Gate 3, B2): a successful remote fetch
/// must drop local rows absent from the fetched list so hard-deleted
/// teams/tournaments cannot resurrect from the offline snapshot.
library;

import 'package:chess_manager/models/player.dart';
import 'package:chess_manager/models/team.dart';
import 'package:chess_manager/models/tournament.dart';
import 'package:chess_manager/services/local_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('replaceAllTeams removes local rows absent from the incoming list', () async {
    await LocalDb.saveTeams([
      RosterTeam(id: 't1', name: 'Keep', playerIds: ['1']),
      RosterTeam(id: 't2', name: 'Deleted remotely', playerIds: ['2']),
    ]);
    final ok = await LocalDb.replaceAllTeams([
      RosterTeam(id: 't1', name: 'Keep', playerIds: ['1']),
    ]);
    expect(ok, isTrue);
    final teams = await LocalDb.loadTeams();
    expect(teams!.map((t) => t.id), ['t1']);
  });

  test('replaceAllTournaments removes local rows absent from the incoming list', () async {
    await LocalDb.saveTournaments([
      Tournament(id: 't1', name: 'Keep'),
      Tournament(id: 't2', name: 'Deleted remotely'),
    ]);
    final ok = await LocalDb.replaceAllTournaments([
      Tournament(id: 't1', name: 'Keep'),
    ]);
    expect(ok, isTrue);
    final tournaments = await LocalDb.loadTournaments(const <Player>[]);
    expect(tournaments!.map((t) => t.id), ['t1']);
  });

  test('replaceAllTournaments with an empty list clears the snapshot', () async {
    await LocalDb.saveTournaments([Tournament(id: 't1', name: 'Gone')]);
    await LocalDb.replaceAllTournaments(const []);
    expect((await LocalDb.loadTournaments(const <Player>[]))!, isEmpty);
  });
}

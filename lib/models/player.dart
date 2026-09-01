/// Player model for the chess club roster.
library;

/// Field names and JSON keys mirror the `players` table schema in
/// ORCHESTRATOR_BUILD_PROMPT.md §2 exactly (snake_case text keys), because the
/// values round-trip through Supabase as raw text columns (§10.3).

/// FIDE-style title. Serialized as the EXACT §2 strings
/// (`'' | GM | IM | FM | CM | NM`); [PlayerTitle.none] serializes to `''`.
enum PlayerTitle {
  none(''),
  grandmaster('GM'),
  internationalMaster('IM'),
  fideMaster('FM'),
  candidateMaster('CM'),
  nationalMaster('NM');

  const PlayerTitle(this.value);

  /// Exact text stored in the `title` column (§2).
  final String value;

  /// Lenient decode per §7.5: unknown/renamed titles coerce to no title.
  static PlayerTitle fromValue(String? value) =>
      PlayerTitle.values.where((t) => t.value == value).firstOrNull ??
      PlayerTitle.none;
}

/// Gender enum. Values are the EXACT §2 check-constraint strings.
enum PlayerGender {
  male('male'),
  female('female'),
  other('other');

  const PlayerGender(this.value);

  /// Exact text stored in the `gender` column (§2).
  final String value;

  /// Lenient decode per §7.5: unknown/renamed values silently coerce to
  /// [male] instead of throwing. Intentional — this masks data corruption on
  /// purpose, matching the source app's behavior.
  static PlayerGender fromValue(String? value) =>
      PlayerGender.values.where((g) => g.value == value).firstOrNull ??
      PlayerGender.male;
}

/// Membership status. Values are the EXACT §2 check-constraint strings.
enum MemberStatus {
  member('member'),
  guest('guest');

  const MemberStatus(this.value);

  /// Exact text stored in the `member_status` column (§2).
  final String value;

  /// Lenient decode per §7.5: unknown/renamed values silently coerce to
  /// [member] instead of throwing. Intentional — see §7.5.
  static MemberStatus fromValue(String? value) =>
      MemberStatus.values.where((s) => s.value == value).firstOrNull ??
      MemberStatus.member;
}

/// A club roster member.
///
/// Note on legacy decode fallbacks (§7.7): the source app's `Player.fromJson`
/// had a migration path deriving `firstName`/`lastName` from a single legacy
/// `name` field, and both ratings from a single legacy `rating` field. That
/// fallback is DELIBERATELY OMITTED here — this is a clean rebuild with a
/// fresh schema, so legacy single-name/rating export files are not supported.
class Player {
  Player({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.blitzRating = 1500,
    this.rapidRating = 1500,
    this.email,
    this.phone,
    this.title = PlayerTitle.none,
    this.gender = PlayerGender.male,
    this.memberStatus = MemberStatus.member,
    this.college = '',
    this.program = '',
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.isActive = true,
  });

  /// App-generated sequential 6-digit id (>= 100000), NOT a UUID (§7.1).
  final String id;

  String firstName;
  String lastName;

  /// Independent blitz Elo pool (§4.6 — two separate rating pools).
  int blitzRating;

  /// Independent rapid Elo pool (§4.6 — two separate rating pools).
  int rapidRating;

  String? email;
  String? phone;

  /// `'' | GM | IM | FM | CM | NM` (§2).
  PlayerTitle title;

  PlayerGender gender;

  /// member / guest (§2).
  MemberStatus memberStatus;

  /// College (members) or school (guests). Defaults to `''`.
  String college;

  /// Course/degree (members) or grade (guests). Defaults to `''`.
  String program;

  int wins;
  int losses;
  int draws;

  /// Soft-delete flag (§4.2): the ONLY player deletion mechanism is setting
  /// this false — inactive players stay in the roster for history integrity.
  bool isActive;

  // ---------------------------------------------------------------------------
  // Derived metrics (§4.2) — zero-guarded, computed on access (no caching).
  // ---------------------------------------------------------------------------

  /// gamesPlayed = wins + draws + losses (§4.2).
  int get gamesPlayed => wins + draws + losses;

  /// score = wins + draws * 0.5 (§4.2).
  double get score => wins + draws * 0.5;

  /// winRate = wins / gamesPlayed, 0 when gamesPlayed == 0 (zero-guarded, §4.2).
  double get winRate => gamesPlayed == 0 ? 0 : wins / gamesPlayed;

  // ---------------------------------------------------------------------------
  // ID generation
  // ---------------------------------------------------------------------------

  /// Max numeric existing id + 1, floored at 100000 (§4.2). Non-numeric ids
  /// in [existing] are ignored when computing the max.
  static String nextId(List<Player> existing) {
    var max = 99999; // floor of 100000 emerges naturally: 99999 + 1
    for (final p in existing) {
      final parsed = int.tryParse(p.id);
      if (parsed != null && parsed > max) max = parsed;
    }
    return (max + 1).toString();
  }

  // ---------------------------------------------------------------------------
  // copyWith
  // ---------------------------------------------------------------------------

  /// Returns a copy with the given fields replaced. Omitted fields keep the
  /// original value; in particular the id is preserved by default, so the
  /// `copyWith(id: originalId)` edit pattern works (§7.1).
  Player copyWith({
    String? id,
    String? firstName,
    String? lastName,
    int? blitzRating,
    int? rapidRating,
    String? email,
    String? phone,
    PlayerTitle? title,
    PlayerGender? gender,
    MemberStatus? memberStatus,
    String? college,
    String? program,
    int? wins,
    int? losses,
    int? draws,
    bool? isActive,
  }) {
    return Player(
      id: id ?? this.id,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      blitzRating: blitzRating ?? this.blitzRating,
      rapidRating: rapidRating ?? this.rapidRating,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      title: title ?? this.title,
      gender: gender ?? this.gender,
      memberStatus: memberStatus ?? this.memberStatus,
      college: college ?? this.college,
      program: program ?? this.program,
      wins: wins ?? this.wins,
      losses: losses ?? this.losses,
      draws: draws ?? this.draws,
      isActive: isActive ?? this.isActive,
    );
  }

  // ---------------------------------------------------------------------------
  // JSON — keys match §2 players columns EXACTLY.
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'first_name': firstName,
    'last_name': lastName,
    'blitz_rating': blitzRating,
    'rapid_rating': rapidRating,
    'email': email,
    'phone': phone,
    'title': title.value,
    'gender': gender.value,
    'member_status': memberStatus.value,
    'college': college,
    'program': program,
    'wins': wins,
    'losses': losses,
    'draws': draws,
    'is_active': isActive,
  };

  factory Player.fromJson(Map<String, dynamic> json) {
    return Player(
      id: json['id'] as String? ?? '',
      firstName: json['first_name'] as String? ?? '',
      lastName: json['last_name'] as String? ?? '',
      blitzRating: (json['blitz_rating'] as num?)?.toInt() ?? 1500,
      rapidRating: (json['rapid_rating'] as num?)?.toInt() ?? 1500,
      email: json['email'] as String?,
      phone: json['phone'] as String?,
      title: PlayerTitle.fromValue(json['title'] as String?),
      // Lenient enum decode (§7.5) — intentional, see enum doc comments.
      gender: PlayerGender.fromValue(json['gender'] as String?),
      memberStatus: MemberStatus.fromValue(json['member_status'] as String?),
      college: json['college'] as String? ?? '',
      program: json['program'] as String? ?? '',
      wins: (json['wins'] as num?)?.toInt() ?? 0,
      losses: (json['losses'] as num?)?.toInt() ?? 0,
      draws: (json['draws'] as num?)?.toInt() ?? 0,
      isActive: json['is_active'] as bool? ?? true,
    );
  }
}

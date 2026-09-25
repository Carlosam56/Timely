part of '../main.dart';

class WebUntisSessionExpired implements Exception {
  @override
  String toString() => 'Exception: WebUntis-Sitzung abgelaufen.';
}

class SchoolSchedule {
  /// Gaps between two periods of at least this many minutes count as a real
  /// break: same-subject lessons are never merged across one.
  static const int _longBreakMinutes = 15;

  /// Used until the school's own grid is known (or if WebUntis doesn't offer
  /// it): 45-minute periods from 08:30 to 17:15.
  static final SchoolSchedule fallback = SchoolSchedule.fromPeriods(const [
    [8 * 60 + 30, 9 * 60 + 15],
    [9 * 60 + 15, 10 * 60],
    [10 * 60 + 20, 11 * 60 + 5],
    [11 * 60 + 10, 11 * 60 + 55],
    [12 * 60, 12 * 60 + 45],
    [13 * 60 + 15, 14 * 60],
    [14 * 60 + 5, 14 * 60 + 50],
    [15 * 60, 15 * 60 + 45],
    [15 * 60 + 45, 16 * 60 + 30],
    [16 * 60 + 30, 17 * 60 + 15],
  ]);

  /// (start, end) of every lesson period, sorted by start.
  final List<List<int>> periods;

  /// Every start and end time, sorted - where the hour lines and labels go.
  final List<int> boundaries;

  final Set<int> lessonStarts;
  final List<List<int>> longBreaks;

  /// Range shown by the grid. Normally first start / last end of the grid;
  /// [coveringLessons] can widen it.
  final int dayStart;
  final int dayEnd;

  SchoolSchedule._({
    required this.periods,
    required this.boundaries,
    required this.lessonStarts,
    required this.longBreaks,
    required this.dayStart,
    required this.dayEnd,
  });

  factory SchoolSchedule.fromPeriods(List<List<int>> raw) {
    final sorted = raw
        .where((p) => p.length == 2 && p[1] > p[0])
        .map((p) => [p[0], p[1]])
        .toList()
      ..sort((a, b) => a[0].compareTo(b[0]));

    final periods = <List<int>>[];
    for (final p in sorted) {
      final last = periods.isEmpty ? null : periods.last;
      if (last != null && last[0] == p[0] && last[1] == p[1]) continue;
      periods.add(p);
    }

    if (periods.isEmpty) return fallback;

    final boundaries = <int>{for (final p in periods) ...p}.toList()..sort();

    final longBreaks = <List<int>>[];
    for (var i = 0; i < periods.length - 1; i++) {
      final breakStart = periods[i][1];
      final breakEnd = periods[i + 1][0];
      if (breakEnd - breakStart >= _longBreakMinutes) {
        longBreaks.add([breakStart, breakEnd]);
      }
    }

    return SchoolSchedule._(
      periods: periods,
      boundaries: boundaries,
      lessonStarts: {for (final p in periods) p[0]},
      longBreaks: longBreaks,
      dayStart: periods.first[0],
      dayEnd: periods.map((p) => p[1]).reduce((a, b) => a > b ? a : b),
    );
  }

  /// Reads WebUntis' `getTimegridUnits` answer. Uses the weekday with the
  /// most periods (Mon-Fri). Returns null if there's nothing usable.
  static SchoolSchedule? fromTimegrid(dynamic result) {
    if (result is! List) return null;

    List<List<int>>? best;

    for (final day in result) {
      if (day is! Map) continue;

      // WebUntis numbers days 1 = Sunday ... 7 = Saturday.
      final dayNumber = _toInt(day['day']);
      if (dayNumber != null && (dayNumber < 2 || dayNumber > 6)) continue;

      final units = day['timeUnits'];
      if (units is! List) continue;

      final periods = <List<int>>[];
      for (final unit in units) {
        if (unit is! Map) continue;
        final start = _untisTimeToMinutes(unit['startTime']);
        final end = _untisTimeToMinutes(unit['endTime']);
        if (start == null || end == null || end <= start) continue;
        periods.add([start, end]);
      }

      if (best == null || periods.length > best.length) best = periods;
    }

    if (best == null || best.isEmpty) return null;
    return SchoolSchedule.fromPeriods(best);
  }

  static SchoolSchedule? fromJsonString(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final periods = <List<int>>[];
      for (final item in decoded) {
        if (item is! List || item.length != 2) continue;
        final start = _toInt(item[0]);
        final end = _toInt(item[1]);
        if (start == null || end == null) continue;
        periods.add([start, end]);
      }
      if (periods.isEmpty) return null;
      return SchoolSchedule.fromPeriods(periods);
    } catch (_) {
      return null;
    }
  }

  String toJsonString() => jsonEncode(periods);

  bool isLessonStart(int minutes) => lessonStarts.contains(minutes);

  /// Whether a lesson ending at [previousEnd] and one starting at
  /// [lessonStart] are separated by a real break.
  bool crossesLongBreak(int previousEnd, int lessonStart) {
    for (final b in longBreaks) {
      if (previousEnd <= b[0] && lessonStart >= b[1]) return true;
    }
    return false;
  }

  /// Vertical nudge (px) for the label of the gridline at [time]. -8 centers
  /// a label on its line; the first/last would be clipped by the grid edge,
  /// and two boundaries only a few minutes apart (a 5-minute break) would
  /// otherwise draw their labels on top of each other.
  double labelOffset(int time, {double pixelsPerMinute = 80.0 / 60.0}) {
    if (time == dayStart) return 0;
    if (time == dayEnd) return -15;

    final i = boundaries.indexOf(time);
    if (i >= 0) {
      const closePixels = 10.0;
      if (i + 1 < boundaries.length &&
          (boundaries[i + 1] - time) * pixelsPerMinute < closePixels) {
        return -12; // push up
      }
      if (i > 0 && (time - boundaries[i - 1]) * pixelsPerMinute < closePixels) {
        return -3; // push down
      }
    }

    return -8;
  }

  /// A copy whose range also covers [lessons] (rounded to full hours), so a
  /// lesson outside the school's normal grid isn't drawn off-screen.
  SchoolSchedule coveringLessons(Iterable<Lesson> lessons) {
    var start = dayStart;
    var end = dayEnd;

    for (final lesson in lessons) {
      final s = lesson.startTime.hour * 60 + lesson.startTime.minute;
      final e = lesson.endTime.hour * 60 + lesson.endTime.minute;
      if (s < start) start = (s ~/ 60) * 60;
      if (e > end) end = ((e + 59) ~/ 60) * 60;
    }

    if (start == dayStart && end == dayEnd) return this;

    return SchoolSchedule._(
      periods: periods,
      boundaries: boundaries,
      lessonStarts: lessonStarts,
      longBreaks: longBreaks,
      dayStart: start,
      dayEnd: end,
    );
  }
}

class WebUntisSession {
  final String sessionId;
  final int personId;
  final int personType;

  WebUntisSession({
    required this.sessionId,
    required this.personId,
    required this.personType,
  });
}

class UserProfile {
  final String id;
  final String username;
  final String fullName;
  final String bio;
  final String? schoolId;
  final String? webUntisSchool;
  final String? webUntisUsername;
  final String? avatarUrl;

  UserProfile({
    required this.id,
    required this.username,
    required this.fullName,
    this.bio = '',
    this.schoolId,
    this.webUntisSchool,
    this.webUntisUsername,
    this.avatarUrl,
  });

  String get displayName => fullName.isNotEmpty ? fullName : username;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'].toString(),
      username: json['username']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? '',
      bio: json['bio']?.toString() ?? '',
      schoolId: json['school_id']?.toString(),
      webUntisSchool: json['webuntis_school']?.toString(),
      webUntisUsername: json['webuntis_username']?.toString(),
      avatarUrl: json['avatar_url']?.toString(),
    );
  }

  Map<String, dynamic> toCacheJson() {
    return {
      'id': id,
      'username': username,
      'full_name': fullName,
      'bio': bio,
      'school_id': schoolId,
      'webuntis_school': webUntisSchool,
      'webuntis_username': webUntisUsername,
      'avatar_url': avatarUrl,
    };
  }

  /// [avatarUrl] updates the picture; pass [clearAvatar] to remove it
  /// (a plain null argument means "leave unchanged", so removal needs its
  /// own flag).
  UserProfile copyWith({
    String? username,
    String? bio,
    String? webUntisSchool,
    String? webUntisUsername,
    String? avatarUrl,
    bool clearAvatar = false,
  }) {
    return UserProfile(
      id: id,
      username: username ?? this.username,
      fullName: fullName,
      bio: bio ?? this.bio,
      schoolId: schoolId,
      webUntisSchool: webUntisSchool ?? this.webUntisSchool,
      webUntisUsername: webUntisUsername ?? this.webUntisUsername,
      avatarUrl: clearAvatar ? null : (avatarUrl ?? this.avatarUrl),
    );
  }
}

class FriendRequest {
  final String id;
  final String requesterId;
  final String addresseeId;
  final String status;
  final UserProfile otherProfile;

  FriendRequest({
    required this.id,
    required this.requesterId,
    required this.addresseeId,
    required this.status,
    required this.otherProfile,
  });

  factory FriendRequest.fromJson(
    Map<String, dynamic> json,
    String currentUserId,
  ) {
    final requester = Map<String, dynamic>.from(json['requester'] as Map);
    final addressee = Map<String, dynamic>.from(json['addressee'] as Map);
    final requesterId = json['requester_id'].toString();
    final addresseeId = json['addressee_id'].toString();
    final other = requesterId == currentUserId ? addressee : requester;

    return FriendRequest(
      id: json['id'].toString(),
      requesterId: requesterId,
      addresseeId: addresseeId,
      status: json['status'].toString(),
      otherProfile: UserProfile.fromJson(other),
    );
  }
}

class FriendData {
  final List<FriendRequest> incoming;
  final List<FriendRequest> outgoing;
  final List<FriendRequest> accepted;

  FriendData({
    required this.incoming,
    required this.outgoing,
    required this.accepted,
  });
}

class FriendGroup {
  final String id;
  final String name;
  final String ownerId;
  final String avatarEmoji;
  final int avatarColor;
  final String? avatarUrl;
  final List<UserProfile> members;

  FriendGroup({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.avatarEmoji,
    required this.avatarColor,
    this.avatarUrl,
    required this.members,
  });

  FriendGroup copyWith({
    String? name,
    String? avatarEmoji,
    List<UserProfile>? members,
  }) {
    return FriendGroup(
      id: id,
      name: name ?? this.name,
      ownerId: ownerId,
      avatarEmoji: avatarEmoji ?? this.avatarEmoji,
      avatarColor: avatarColor,
      avatarUrl: avatarUrl,
      members: members ?? this.members,
    );
  }

  factory FriendGroup.fromJson(Map<String, dynamic> json, List<UserProfile> members) {
    return FriendGroup(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? '',
      ownerId: json['owner_id'].toString(),
      avatarEmoji: json['avatar_emoji']?.toString() ?? '👥',
      avatarColor: _toInt(json['avatar_color']) ?? 0xFF8B5CF6,
      avatarUrl: json['avatar_url']?.toString(),
      members: members,
    );
  }
}

class Lesson {
  final int id;
  final DateTime date;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final String subject;
  final String teacher;
  final String room;
  final bool cancelled;
  final String studentGroup;
  final String activityType;

  Lesson({
    required this.id,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.subject,
    required this.teacher,
    required this.room,
    required this.cancelled,
    required this.studentGroup,
    required this.activityType,
  });

  factory Lesson.fromJson(
    Map<String, dynamic> json, {
    required Map<int, String> subjects,
    required Map<int, String> teachers,
    required Map<int, String> rooms,
  }) {
    final subjectId = _extractFirstId(json['su']);
    final teacherId = _extractFirstId(json['te']);
    final roomId = _extractFirstId(json['ro']);

    return Lesson(
      id: _toInt(json['id']) ?? 0,
      date: _parseUntisDate(json['date']),
      startTime: _parseUntisTime(json['startTime']),
      endTime: _parseUntisTime(json['endTime']),
      subject:
          subjects[subjectId] ??
          (subjectId != null ? 'Fach #$subjectId' : 'Unbekanntes Fach'),
      teacher:
          teachers[teacherId] ??
          (teacherId != null && teachers.isNotEmpty ? 'Lehrer #$teacherId' : ''),
      room: rooms[roomId] ??
          (roomId != null && rooms.isNotEmpty ? 'Raum #$roomId' : ''),
      cancelled: json['code']?.toString() == 'cancelled',
      studentGroup: json['sg']?.toString() ?? '',
      activityType: json['activityType']?.toString() ?? '',
    );
  }

  /// Serializes this lesson with names already resolved (no WebUntis IDs),
  /// so it can be stored for friends to read without them needing our
  /// subject/teacher/room ID mappings.
  Map<String, dynamic> toStoredJson() {
    return {
      'id': id,
      'date': _formatUntisDate(date),
      'startTime': startTime.hour * 100 + startTime.minute,
      'endTime': endTime.hour * 100 + endTime.minute,
      'subject': subject,
      'teacher': teacher,
      'room': room,
      'cancelled': cancelled,
      'studentGroup': studentGroup,
      'activityType': activityType,
    };
  }

  factory Lesson.fromStoredJson(Map<String, dynamic> json) {
    return Lesson(
      id: _toInt(json['id']) ?? 0,
      date: _parseUntisDate(json['date']),
      startTime: _parseUntisTime(json['startTime']),
      endTime: _parseUntisTime(json['endTime']),
      subject: json['subject']?.toString() ?? '',
      teacher: json['teacher']?.toString() ?? '',
      room: json['room']?.toString() ?? '',
      cancelled: json['cancelled'] == true,
      studentGroup: json['studentGroup']?.toString() ?? '',
      activityType: json['activityType']?.toString() ?? '',
    );
  }

  /// What makes two lessons "the same class": same subject taught by the
  /// same teacher. Just matching the subject name let two people in
  /// different "Deutsch" courses show up as sharing a class. If either
  /// side has no teacher listed, the subject alone decides (better than
  /// never matching at all).
  bool _isSameClassAs(Lesson other) {
    if (subject.trim().toLowerCase() != other.subject.trim().toLowerCase()) {
      return false;
    }

    final myTeacher = teacher.trim().toLowerCase();
    final otherTeacher = other.teacher.trim().toLowerCase();

    return myTeacher.isEmpty || otherTeacher.isEmpty || myTeacher == otherTeacher;
  }

  /// Whether this lesson and [other] represent "the same class" for the
  /// purposes of the friends timetable comparison (same day, same start
  /// time, same subject+teacher).
  bool matchesForComparison(Lesson other) {
    return date.year == other.date.year &&
        date.month == other.date.month &&
        date.day == other.date.day &&
        startTime.hour == other.startTime.hour &&
        startTime.minute == other.startTime.minute &&
        _isSameClassAs(other);
  }
}
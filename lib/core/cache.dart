part of '../main.dart';

const _profileCachePrefix = 'profile_cache_v1_';

const _untisPersonCachePrefix = 'untis_person_cache_v1_';

/// True for errors that just mean "no usable connection" (as opposed to the
/// server answering with a real rejection like a wrong password).
/// Applied to every Supabase call so a bad connection fails with a message
/// instead of leaving the UI stuck loading.

const _supabaseTimeout = Duration(seconds: 15);

bool _isNetworkError(Object error) {
  if (error is TimeoutException || error is http.ClientException) return true;
  final type = error.runtimeType.toString();
  return type.contains('SocketException') ||
      type.contains('HandshakeException') ||
      type.contains('RetryableFetch');
}

/// The last successfully loaded profile (incl. the WebUntis school/username
/// hint), so a cold start without internet can still open the app.

Future<void> _saveProfileToCache(UserProfile profile) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    '$_profileCachePrefix${profile.id}',
    jsonEncode(profile.toCacheJson()),
  );
}

Future<UserProfile?> _loadProfileFromCache() async {
  final userId = supabase.auth.currentUser?.id;
  if (userId == null) return null;

  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('$_profileCachePrefix$userId');
  if (raw == null || raw.isEmpty) return null;

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return UserProfile.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    return null;
  }
}

/// WebUntis personId/personType from the last successful login. They don't
/// change between sessions, and the offline timetable needs no session at all.

Future<void> _saveUntisPersonToCache(WebUntisSession session) async {
  final userId = supabase.auth.currentUser?.id;
  if (userId == null) return;

  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    '$_untisPersonCachePrefix$userId',
    jsonEncode({'personId': session.personId, 'personType': session.personType}),
  );
}

/// Returns a session with an empty sessionId: "known person, but not logged
/// in to WebUntis yet". [_HomePageState] logs in again when it needs to.

Future<WebUntisSession?> _loadUntisPersonFromCache() async {
  final userId = supabase.auth.currentUser?.id;
  if (userId == null) return null;

  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('$_untisPersonCachePrefix$userId');
  if (raw == null || raw.isEmpty) return null;

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final personId = _toInt(decoded['personId']);
    final personType = _toInt(decoded['personType']);
    if (personId == null || personType == null) return null;
    return WebUntisSession(
      sessionId: '',
      personId: personId,
      personType: personType,
    );
  } catch (_) {
    return null;
  }
}

const _scheduleCachePrefix = 'school_schedule_cache_v1_';

Future<SchoolSchedule?> _loadScheduleFromCache(String school) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('$_scheduleCachePrefix${school.toLowerCase()}');
  if (raw == null || raw.isEmpty) return null;
  return SchoolSchedule.fromJsonString(raw);
}

Future<void> _saveScheduleToCache(String school, SchoolSchedule schedule) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    '$_scheduleCachePrefix${school.toLowerCase()}',
    schedule.toJsonString(),
  );
}

class _CachedTimetableWeek {
  final DateTime updatedAt;
  final List<Lesson> lessons;

  _CachedTimetableWeek({required this.updatedAt, required this.lessons});
}

String _timetableCacheKey(DateTime weekStart) {
  final userId = supabase.auth.currentUser?.id ?? 'local';
  return '$_timetableCachePrefix${userId}_${_formatIsoDate(weekStart)}';
}

Future<void> _saveTimetableWeekToCache({
  required DateTime weekStart,
  required List<Lesson> lessons,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _timetableCacheKey(weekStart),
    jsonEncode({
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'lessons': lessons.map((lesson) => lesson.toStoredJson()).toList(),
    }),
  );
}

Future<_CachedTimetableWeek?> _loadTimetableWeekFromCache(
  DateTime weekStart,
) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_timetableCacheKey(weekStart));
  if (raw == null || raw.isEmpty) return null;

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;

    final updatedAt = DateTime.tryParse(decoded['updatedAt']?.toString() ?? '');
    final rawLessons = decoded['lessons'];
    if (updatedAt == null || rawLessons is! List) return null;

    final lessons = rawLessons
        .whereType<Map>()
        .map((item) => Lesson.fromStoredJson(Map<String, dynamic>.from(item)))
        .toList();

    return _CachedTimetableWeek(
      updatedAt: updatedAt.toLocal(),
      lessons: lessons,
    );
  } catch (_) {
    return null;
  }
}
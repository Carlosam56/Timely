part of '../main.dart';

Future<void> _restoreAndPersistAppearancePrefs() async {
  final prefs = await SharedPreferences.getInstance();

  final savedThemeMode = prefs.getString(_themeModePrefKey);
  if (savedThemeMode == 'light') {
    appThemeMode.value = ThemeMode.light;
  } else if (savedThemeMode == 'dark') {
    appThemeMode.value = ThemeMode.dark;
  }

  final savedAccentColor = prefs.getInt(_accentColorPrefKey);
  if (savedAccentColor != null) {
    appAccentColor.value = Color(savedAccentColor);
  }

  final savedShowCancelled = prefs.getBool(_showCancelledLessonsPrefKey);
  if (savedShowCancelled != null) {
    appShowCancelledLessons.value = savedShowCancelled;
  }

  appShareTimetable.value = prefs.getBool(_shareTimetablePrefKey) ?? false;

  appThemeMode.addListener(() {
    prefs.setString(
      _themeModePrefKey,
      appThemeMode.value == ThemeMode.light ? 'light' : 'dark',
    );
  });
  appAccentColor.addListener(() {
    prefs.setInt(_accentColorPrefKey, appAccentColor.value.toARGB32());
  });
  appShowCancelledLessons.addListener(() {
    prefs.setBool(_showCancelledLessonsPrefKey, appShowCancelledLessons.value);
  });
  appShareTimetable.addListener(() {
    prefs.setBool(_shareTimetablePrefKey, appShareTimetable.value);
  });
}

// The WebUntis password lives in the platform keystore (Android Keystore /
// iOS Keychain), never in plain SharedPreferences.

const _secureStorage = FlutterSecureStorage();

/// Reads the saved WebUntis password. Also migrates a password that an
/// older app version left behind in plain SharedPreferences: it is moved
/// into secure storage and the plain copy is deleted.

Future<String?> _readWebUntisPassword() async {
  final prefs = await SharedPreferences.getInstance();

  final legacy = prefs.getString(_webUntisPasswordPrefKey);
  if (legacy != null) {
    try {
      if (legacy.isNotEmpty) {
        await _secureStorage.write(key: _webUntisPasswordPrefKey, value: legacy);
      }
      await prefs.remove(_webUntisPasswordPrefKey);
    } catch (_) {
      // Keep the legacy copy if the migration failed; try again next time.
    }
  }

  try {
    return await _secureStorage.read(key: _webUntisPasswordPrefKey);
  } catch (_) {
    return null;
  }
}

Future<void> _saveWebUntisPassword(String password) async {
  await _secureStorage.write(key: _webUntisPasswordPrefKey, value: password);
}

Future<void> _clearWebUntisPassword() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_webUntisPasswordPrefKey);
  try {
    await _secureStorage.delete(key: _webUntisPasswordPrefKey);
  } catch (_) {}
}

/// Signs out of the Timely (Supabase) account and wipes what this device
/// stored for that user: the WebUntis password, the cached timetables and
/// the sharing choice, so the next login starts clean.

Future<void> _signOutOfTimely() async {
  await _clearWebUntisPassword();

  final prefs = await SharedPreferences.getInstance();
  for (final key in prefs.getKeys().toList()) {
    if (key.startsWith(_timetableCachePrefix) ||
        key.startsWith(_profileCachePrefix) ||
        key.startsWith(_untisPersonCachePrefix)) {
      await prefs.remove(key);
    }
  }
  await prefs.remove(_shareTimetableAskedPrefKey);
  // Only flips the local switch; the HomePage listener reacts to "on" only,
  // so this never deletes anything on the server.
  appShareTimetable.value = false;

  appSchedule.value = SchoolSchedule.fallback;

  await supabase.auth.signOut().timeout(_supabaseTimeout);

  // WebUntisConnectPage used to replace AuthGate with pushReplacement, and
  // the settings pages are pushed on top of HomePage - both left routes
  // above AuthGate that never noticed the sign-out. Popping back to the
  // first route guarantees AuthGate (which is always that first route) is
  // what's on screen once this returns.
  rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
}

Future<List<String>> _loadRecentSchools() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(_recentSchoolsPrefKey) ?? [];
}

/// Remembers a successfully used school name so it can be suggested again
/// next time the user starts typing it (most recent first, capped at 8).

Future<void> _rememberSchool(String school) async {
  final prefs = await SharedPreferences.getInstance();
  final current = prefs.getStringList(_recentSchoolsPrefKey) ?? [];
  current.removeWhere((s) => s.toLowerCase() == school.toLowerCase());
  current.insert(0, school);
  if (current.length > 8) {
    current.removeRange(8, current.length);
  }
  await prefs.setStringList(_recentSchoolsPrefKey, current);
}

// --- Onboarding ---------------------------------------------------------

const _onboardingSeenPrefKey = 'pref_onboarding_seen';

Future<bool> _hasSeenOnboarding() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_onboardingSeenPrefKey) ?? false;
}

Future<void> _markOnboardingSeen() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_onboardingSeenPrefKey, true);
}

// If someone signs up but Supabase requires email confirmation first, there
// is no active session yet to attach `terms_accepted_at` to. The timestamp
// is parked here and written to their profile the first time
// [ProfileService.loadCurrentProfile] creates it after they confirm and
// log in for real (see `_pendingTermsAcceptedAt` there).

const _pendingTermsAcceptedAtPrefKey = 'pref_pending_terms_accepted_at';

Future<void> _savePendingTermsAcceptedAt(DateTime when) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_pendingTermsAcceptedAtPrefKey, when.toUtc().toIso8601String());
}

Future<DateTime?> _takePendingTermsAcceptedAt() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_pendingTermsAcceptedAtPrefKey);
  if (raw == null) return null;
  await prefs.remove(_pendingTermsAcceptedAtPrefKey);
  return DateTime.tryParse(raw);
}
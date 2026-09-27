import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

part 'core/prefs.dart';
part 'core/cache.dart';
part 'core/formatters.dart';
part 'core/legal_text.dart';
part 'models/models.dart';
part 'services/services.dart';
part 'pages/profile_gate.dart';
part 'pages/reset_password_page.dart';
part 'pages/account_page.dart';
part 'pages/webuntis_connect_page.dart';
part 'pages/home_page.dart';
part 'pages/friends_page.dart';
part 'pages/create_group_page.dart';
part 'pages/group_profile_page.dart';
part 'pages/add_group_members_page.dart';
part 'pages/group_timetable_page.dart';
part 'pages/friend_requests_page.dart';
part 'pages/friend_profile_page.dart';
part 'pages/friend_timetable_page.dart';
part 'pages/onboarding_intro_page.dart';
part 'pages/appearance_picker_page.dart';
part 'widgets/shared_widgets.dart';

const supabaseUrl = 'https://rrnngxbjztnhrcblnbym.supabase.co';

const supabasePublishableKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJybm5neGJqenRuaHJjYmxuYnltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkxNDA0OTcsImV4cCI6MjEwNDcxNjQ5N30.sC0f_IkNVAfrWcOdSadDw7zuka1Ucp-6Sv1ksetNjQU';

// Deep link Supabase redirects to after someone taps the "reset your
// password" link in their email. Must be registered as a Redirect URL in
// the Supabase dashboard (Authentication -> URL Configuration), and as a
// custom URL scheme in the native Android/iOS project - see the setup notes
// near [ResetPasswordPage].

const _passwordResetRedirect = 'timely://reset-password';

const _themeModePrefKey = 'pref_theme_mode';

const _accentColorPrefKey = 'pref_accent_color';

const _webUntisPasswordPrefKey = 'webuntis_password';

const _recentSchoolsPrefKey = 'recent_webuntis_schools';

const _timetableCachePrefix = 'timetable_cache_v1_';

const _showCancelledLessonsPrefKey = 'pref_show_cancelled_lessons';

const _shareTimetablePrefKey = 'pref_share_timetable';

const _shareTimetableAskedPrefKey = 'pref_share_timetable_asked';

final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.dark);

final ValueNotifier<Color> appAccentColor = ValueNotifier(const Color(0xFF8B5CF6));

final ValueNotifier<bool> appShowCancelledLessons = ValueNotifier(true);

/// Whether the user opted in to sharing their timetable with friends and
/// group members. Off by default: nothing is uploaded until the user says yes.

final ValueNotifier<bool> appShareTimetable = ValueNotifier(false);

/// The time grid (lesson periods) of the user's school. Starts as
/// [SchoolSchedule.fallback] and is replaced by the school's real grid from
/// WebUntis. Read by the own, friend and group timetable pages.

final ValueNotifier<SchoolSchedule> appSchedule = ValueNotifier(SchoolSchedule.fallback);

final supabase = Supabase.instance.client;

/// Lets code without a BuildContext (like signing out) reach the root
/// navigator, so it can always get back to the login screen.

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Loads the saved theme mode / accent color (if any) and wires the two
/// notifiers so that any future change the user makes is persisted for
/// the next app start.

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  );

  await _restoreAndPersistAppearancePrefs();

  runApp(const TimelyApp());
}

class TimelyApp extends StatelessWidget {
  const TimelyApp({super.key});

  ThemeData _buildTheme({required Brightness brightness, required Color accent}) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: isDark ? const Color(0xFF09090B) : const Color(0xFFF7F7F8),
      colorScheme: scheme,
      useMaterial3: true,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF18181B) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) {
        return ValueListenableBuilder<Color>(
          valueListenable: appAccentColor,
          builder: (context, accent, _) {
            return MaterialApp(
              navigatorKey: rootNavigatorKey,
              debugShowCheckedModeBanner: false,
              title: 'Timely',
              theme: _buildTheme(brightness: Brightness.light, accent: accent),
              darkTheme: _buildTheme(brightness: Brightness.dark, accent: accent),
              themeMode: mode,
              home: const OnboardingGate(),
            );
          },
        );
      },
    );
  }
}

/// Shown before anything else on first launch: the 3-page explainer, once.
/// Every launch after that (tracked via [_hasSeenOnboarding]) goes straight
/// to [AuthGate]. Replaying the intro later from Settings does not go
/// through here - it's a normal pushed [IntroPage] route instead.
class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key});

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  late Future<bool> _seenFuture;

  @override
  void initState() {
    super.initState();
    _seenFuture = _hasSeenOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _seenFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.data == true) {
          return const AuthGate();
        }
        return IntroPage(
          onFinished: () => setState(() => _seenFuture = Future.value(true)),
        );
      },
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? authSubscription;
  Session? session;
  bool showPasswordRecovery = false;

  // Set for exactly one step right after a brand-new signup, so the
  // appearance picker shows before [ProfileGate] takes over - regardless of
  // how quickly the auth-state stream flips [session] to non-null.
  bool showAppearanceStep = false;

  @override
  void initState() {
    super.initState();
    session = supabase.auth.currentSession;
    authSubscription = supabase.auth.onAuthStateChange.listen((data) {
      if (!mounted) return;
      setState(() {
        session = data.session;
        if (data.event == AuthChangeEvent.passwordRecovery) {
          showPasswordRecovery = true;
        }
      });
    });
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Someone tapped the "reset your password" link from their email - make
    // them set a new one before letting them into the app, regardless of
    // whether Supabase already handed us a (temporary) recovery session.
    if (showPasswordRecovery) {
      return ResetPasswordPage(
        onDone: () {
          if (!mounted) return;
          setState(() => showPasswordRecovery = false);
        },
      );
    }

    if (showAppearanceStep) {
      return AppearancePickerPage(
        onDone: () {
          if (!mounted) return;
          setState(() => showAppearanceStep = false);
        },
      );
    }

    if (session == null) {
      return AccountPage(
        onAccountCreated: () {
          if (!mounted) return;
          setState(() => showAppearanceStep = true);
        },
      );
    }

    return const ProfileGate();
  }
}

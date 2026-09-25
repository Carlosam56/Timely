part of '../main.dart';

class ProfileGate extends StatefulWidget {
  const ProfileGate({super.key});

  @override
  State<ProfileGate> createState() => _ProfileGateState();
}

/// Result of loading the Timely profile and, if possible, silently
/// re-authenticating with WebUntis using a password saved on this device.

class _ProfileLoadResult {
  final UserProfile profile;
  final WebUntisSession? session;

  _ProfileLoadResult({required this.profile, this.session});
}

class _ProfileGateState extends State<ProfileGate> {
  late Future<_ProfileLoadResult> profileFuture;

  @override
  void initState() {
    super.initState();
    profileFuture = _loadProfileAndTryAutoLogin();
  }

  Future<_ProfileLoadResult> _loadProfileAndTryAutoLogin() async {
    UserProfile profile;
    try {
      profile = await ProfileService.loadCurrentProfile().timeout(
        const Duration(seconds: 15),
      );
      unawaited(_saveProfileToCache(profile));
    } catch (_) {
      // Offline (or Supabase unreachable): fall back to the last known
      // profile so the cached timetable is still reachable.
      final cached = await _loadProfileFromCache();
      if (cached == null) rethrow;
      profile = cached;
    }

    final school = profile.webUntisSchool;
    final username = profile.webUntisUsername;

    if (school == null ||
        school.isEmpty ||
        username == null ||
        username.isEmpty) {
      return _ProfileLoadResult(profile: profile);
    }

    final savedPassword = await _readWebUntisPassword();

    if (savedPassword == null || savedPassword.isEmpty) {
      return _ProfileLoadResult(profile: profile);
    }

    try {
      final session = await WebUntisService.authenticate(
        school: school,
        username: username,
        password: savedPassword,
      );
      return _ProfileLoadResult(profile: profile, session: session);
    } catch (e) {
      if (_isNetworkError(e)) {
        // No connection, not a wrong password: open the app on the cached
        // timetable. HomePage logs in again as soon as it needs the network.
        final person = await _loadUntisPersonFromCache();
        if (person != null) {
          return _ProfileLoadResult(profile: profile, session: person);
        }
      }
      // The saved password no longer works (changed/expired) - fall back
      // to the manual WebUntis login screen instead of failing silently.
      return _ProfileLoadResult(profile: profile);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ProfileLoadResult>(
      future: profileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 56,
                      color: Colors.redAccent,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Profil konnte nicht geladen werden',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _cleanError(snapshot.error!),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          profileFuture = _loadProfileAndTryAutoLogin();
                        });
                      },
                      child: const Text('Erneut versuchen'),
                    ),
                    TextButton(
                      onPressed: () => _signOutOfTimely(),
                      child: const Text('Abmelden'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final result = snapshot.data!;

        if (result.session != null) {
          return HomePage(
            profile: result.profile,
            school: result.profile.webUntisSchool!,
            username: result.profile.webUntisUsername!,
            sessionId: result.session!.sessionId,
            personId: result.session!.personId,
            personType: result.session!.personType,
          );
        }

        return WebUntisConnectPage(profile: result.profile);
      },
    );
  }
}

/// Shown when Supabase hands the app a password-recovery session (the user
/// tapped the reset link from their email). Lets them set a brand new
/// password, then hands control back to [AuthGate] via [onDone].
///
/// Native setup required for the email link to actually reach this screen:
/// - Add `timely://reset-password` as a Redirect URL in the Supabase
///   dashboard under Authentication -> URL Configuration.
/// - Android: register the `timely` scheme as an intent filter on the main
///   activity in android/app/src/main/AndroidManifest.xml.
/// - iOS: register `timely` as a URL scheme in ios/Runner/Info.plist.
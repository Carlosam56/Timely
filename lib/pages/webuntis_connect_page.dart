part of '../main.dart';

class WebUntisConnectPage extends StatefulWidget {
  final UserProfile profile;

  const WebUntisConnectPage({super.key, required this.profile});

  @override
  State<WebUntisConnectPage> createState() => _WebUntisConnectPageState();
}

class _WebUntisConnectPageState extends State<WebUntisConnectPage> {
  late final TextEditingController schoolController;
  late final FocusNode schoolFocusNode;
  late final TextEditingController usernameController;
  final passwordController = TextEditingController();

  bool obscurePassword = true;
  bool loading = false;
  String? errorMessage;
  List<String> recentSchools = [];

  @override
  void initState() {
    super.initState();
    schoolController = TextEditingController(
      text: widget.profile.webUntisSchool ?? '',
    );
    schoolFocusNode = FocusNode();
    usernameController = TextEditingController(
      text: widget.profile.webUntisUsername ?? '',
    );
    _loadRecentSchools().then((schools) {
      if (mounted) {
        setState(() {
          recentSchools = schools;
        });
      }
    });
  }

  @override
  void dispose() {
    schoolController.dispose();
    schoolFocusNode.dispose();
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> connectWebUntis() async {
    final school = schoolController.text.trim();
    final username = usernameController.text.trim();
    final password = passwordController.text;

    if (school.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() {
        errorMessage = 'Bitte fülle alle WebUntis-Felder aus.';
      });
      return;
    }

    setState(() {
      loading = true;
      errorMessage = null;
    });

    try {
      final session = await WebUntisService.authenticate(
        school: school,
        username: username,
        password: password,
      );

      await ProfileService.saveWebUntisHint(school: school, username: username);
      await _rememberSchool(school);

      await _saveWebUntisPassword(password);

      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => HomePage(
            profile: widget.profile.copyWith(
              webUntisSchool: school,
              webUntisUsername: username,
            ),
            school: school,
            username: username,
            sessionId: session.sessionId,
            personId: session.personId,
            personType: session.personType,
          ),
        ),
        (route) => route.isFirst,
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        errorMessage = _cleanError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 450),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 40),
                  const _TimelyLogo(),
                  const SizedBox(height: 24),
                  const Text(
                    'WebUntis verbinden',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Angemeldet als ${widget.profile.displayName}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 36),
                  Autocomplete<String>(
                    textEditingController: schoolController,
                    focusNode: schoolFocusNode,
                    optionsBuilder: (TextEditingValue value) {
                      final query = value.text.trim().toLowerCase();
                      if (query.isEmpty) return const Iterable<String>.empty();
                      return recentSchools.where(
                        (school) => school.toLowerCase().contains(query),
                      );
                    },
                    fieldViewBuilder:
                        (context, controller, focusNode, onFieldSubmitted) {
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'WebUntis-Schule',
                              hintText: 'z. B. schulname',
                              prefixIcon: Icon(Icons.school_outlined),
                            ),
                          );
                        },
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: usernameController,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'WebUntis-Benutzername',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    onSubmitted: (_) => connectWebUntis(),
                    decoration: InputDecoration(
                      labelText: 'WebUntis-Passwort',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () {
                          setState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  if (errorMessage != null) ...[
                    _MessageBox(
                      icon: Icons.error_outline,
                      color: Colors.redAccent,
                      message: errorMessage!,
                    ),
                    const SizedBox(height: 14),
                  ],
                  SizedBox(
                    height: 54,
                    child: FilledButton(
                      onPressed: loading ? null : connectWebUntis,
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('WebUntis verbinden'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: loading ? null : () => _signOutOfTimely(),
                    icon: const Icon(Icons.logout),
                    label: const Text('Timely abmelden'),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
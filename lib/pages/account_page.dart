part of '../main.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, this.onAccountCreated});

  /// Called once, right after a brand-new account was created (not on a
  /// plain login). Lets [AuthGate] insert the appearance-picker step
  /// before handing off to [ProfileGate].
  final VoidCallback? onAccountCreated;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final usernameController = TextEditingController();
  final fullNameController = TextEditingController();

  bool createAccount = true;
  bool obscurePassword = true;
  bool loading = false;
  String? errorMessage;
  String? infoMessage;

  bool termsSeen = false;
  bool privacySeen = false;
  bool termsAccepted = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    usernameController.dispose();
    fullNameController.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final email = emailController.text.trim();
    final password = passwordController.text;
    final username = _normalizeUsername(usernameController.text);
    final fullName = fullNameController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        errorMessage = 'Bitte gib E-Mail und Passwort ein.';
        infoMessage = null;
      });
      return;
    }

    if (createAccount && username.isEmpty) {
      setState(() {
        errorMessage = 'Bitte wähle einen Timely-Benutzernamen.';
        infoMessage = null;
      });
      return;
    }

    if (createAccount && !RegExp(r'^[a-z0-9_]{3,24}$').hasMatch(username)) {
      setState(() {
        errorMessage =
            'Benutzernamen dürfen 3-24 Zeichen haben: a-z, 0-9 und _.';
        infoMessage = null;
      });
      return;
    }

    if (createAccount && !termsAccepted) {
      setState(() {
        errorMessage =
            'Bitte lies und akzeptiere die Nutzungsbedingungen und Datenschutzhinweise.';
        infoMessage = null;
      });
      return;
    }

    setState(() {
      loading = true;
      errorMessage = null;
      infoMessage = null;
    });

    try {
      if (createAccount) {
        final response = await supabase.auth
            .signUp(
              email: email,
              password: password,
              data: {
                'username': username,
                'full_name': fullName.isEmpty ? username : fullName,
              },
            )
            .timeout(_supabaseTimeout);

        final acceptedAt = DateTime.now().toUtc();

        if (response.session == null) {
          // No session yet (email confirmation required): the profile row
          // doesn't exist to attach this to. Park it locally; it's written
          // the moment the profile is first created after confirmation.
          await _savePendingTermsAcceptedAt(acceptedAt);
          setState(() {
            infoMessage = 'Account erstellt. Bitte bestätige deine E-Mail und melde dich danach an.';
          });
        } else {
          await ProfileService.upsertCurrentProfile(
            username: username,
            fullName: fullName.isEmpty ? username : fullName,
            termsAcceptedAt: acceptedAt,
          );
          widget.onAccountCreated?.call();
        }
      } else {
        await supabase.auth
            .signInWithPassword(email: email, password: password)
            .timeout(_supabaseTimeout);
      }
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

  /// Shows a small dialog asking for the account email, then triggers
  /// Supabase's "reset password" email. The link inside that email opens
  /// [_passwordResetRedirect], which [AuthGate] picks up and routes to
  /// [ResetPasswordPage].
  Future<void> _showForgotPasswordDialog() async {
    final resetEmailController = TextEditingController(
      text: emailController.text.trim(),
    );
    bool sending = false;
    String? dialogError;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Future<void> sendResetEmail() async {
              final email = resetEmailController.text.trim();

              if (email.isEmpty || !email.contains('@')) {
                setDialogState(() {
                  dialogError = 'Bitte gib eine gültige E-Mail-Adresse ein.';
                });
                return;
              }

              setDialogState(() {
                sending = true;
                dialogError = null;
              });

              try {
                await supabase.auth
                    .resetPasswordForEmail(email, redirectTo: _passwordResetRedirect)
                    .timeout(_supabaseTimeout);
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                if (!mounted) return;
                setState(() {
                  errorMessage = null;
                  infoMessage =
                      'Falls für $email ein Konto existiert, haben wir einen Link zum Zurücksetzen gesendet. Bitte prüfe dein Postfach.';
                });
              } catch (e) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  sending = false;
                  dialogError = _cleanError(e);
                });
              }
            }

            return AlertDialog(
              title: const Text('Passwort zurücksetzen'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Gib deine E-Mail-Adresse ein. Wir senden dir einen Link, mit dem du ein neues Passwort festlegen kannst.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: resetEmailController,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => sending ? null : sendResetEmail(),
                    decoration: const InputDecoration(
                      labelText: 'E-Mail',
                      prefixIcon: Icon(Icons.mail_outline),
                    ),
                  ),
                  if (dialogError != null) ...[
                    const SizedBox(height: 12),
                    _MessageBox(
                      icon: Icons.error_outline,
                      color: Colors.redAccent,
                      message: dialogError!,
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: sending
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: sending ? null : sendResetEmail,
                  child: sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Link senden'),
                ),
              ],
            );
          },
        );
      },
    );

    resetEmailController.dispose();
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
                    'Timely',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 38, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Erstelle dein Timely-Konto und verbinde danach WebUntis.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 32),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: true,
                        label: Text('Registrieren'),
                        icon: Icon(Icons.person_add_alt_1),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text('Einloggen'),
                        icon: Icon(Icons.login),
                      ),
                    ],
                    selected: {createAccount},
                    onSelectionChanged: loading
                        ? null
                        : (value) {
                            setState(() {
                              createAccount = value.first;
                              errorMessage = null;
                              infoMessage = null;
                            });
                          },
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'E-Mail',
                      prefixIcon: Icon(Icons.mail_outline),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    textInputAction: createAccount
                        ? TextInputAction.next
                        : TextInputAction.done,
                    onSubmitted: (_) {
                      if (!createAccount) submit();
                    },
                    decoration: InputDecoration(
                      labelText: 'Passwort',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  if (createAccount) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: usernameController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Timely-Benutzername',
                        prefixIcon: Icon(Icons.alternate_email),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: fullNameController,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Nutzungsbedingungen'),
                                  content: SingleChildScrollView(child: Text(kTermsText())),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(),
                                      child: const Text('Schließen'),
                                    ),
                                  ],
                                ),
                              );
                              if (!mounted) return;
                              setState(() => termsSeen = true);
                            },
                            icon: Icon(
                              termsSeen ? Icons.check_circle : Icons.description_outlined,
                              size: 18,
                            ),
                            label: const Text('Nutzungsbedingungen'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Privatsphäre'),
                                  content: SingleChildScrollView(child: Text(kPrivacyText())),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(),
                                      child: const Text('Schließen'),
                                    ),
                                  ],
                                ),
                              );
                              if (!mounted) return;
                              setState(() => privacySeen = true);
                            },
                            icon: Icon(
                              privacySeen ? Icons.check_circle : Icons.privacy_tip_outlined,
                              size: 18,
                            ),
                            label: const Text('Datenschutz'),
                          ),
                        ),
                      ],
                    ),
                    CheckboxListTile(
                      value: termsAccepted,
                      onChanged: (termsSeen && privacySeen)
                          ? (value) => setState(() => termsAccepted = value ?? false)
                          : null,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        'Ich habe die Nutzungsbedingungen und Datenschutzhinweise gelesen und akzeptiere sie.',
                        style: TextStyle(
                          fontSize: 13,
                          color: (termsSeen && privacySeen)
                              ? null
                              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ] else ...[
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: loading ? null : _showForgotPasswordDialog,
                        child: const Text('Passwort vergessen?'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (errorMessage != null) ...[
                    _MessageBox(
                      icon: Icons.error_outline,
                      color: Colors.redAccent,
                      message: errorMessage!,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (infoMessage != null) ...[
                    _MessageBox(
                      icon: Icons.mark_email_read_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      message: infoMessage!,
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    height: 54,
                    child: FilledButton(
                      onPressed: loading ? null : submit,
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
                          : Text(
                              createAccount ? 'Account erstellen' : 'Einloggen',
                            ),
                    ),
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
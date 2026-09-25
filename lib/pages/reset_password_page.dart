part of '../main.dart';

class ResetPasswordPage extends StatefulWidget {
  final VoidCallback onDone;

  const ResetPasswordPage({super.key, required this.onDone});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final newPasswordController = TextEditingController();
  final confirmPasswordController = TextEditingController();
  bool obscureNew = true;
  bool obscureConfirm = true;
  bool submitting = false;
  String? errorMessage;

  @override
  void dispose() {
    newPasswordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final newPassword = newPasswordController.text;
    final confirmPassword = confirmPasswordController.text;

    if (newPassword.length < 6) {
      setState(() => errorMessage = 'Mindestens 6 Zeichen erforderlich.');
      return;
    }
    if (newPassword != confirmPassword) {
      setState(() => errorMessage = 'Passwörter stimmen nicht überein.');
      return;
    }

    setState(() {
      submitting = true;
      errorMessage = null;
    });

    try {
      await supabase.auth
          .updateUser(UserAttributes(password: newPassword))
          .timeout(_supabaseTimeout);
      if (!mounted) return;
      widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        submitting = false;
        errorMessage = _cleanError(e);
      });
    }
  }

  Future<void> _cancel() async {
    // They opened the reset link but changed their mind - drop the
    // temporary recovery session rather than leaving them half logged in.
    await supabase.auth.signOut().timeout(_supabaseTimeout);
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.lock_reset_rounded,
                  size: 52,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Neues Passwort festlegen',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Lege ein neues Passwort für dein Timely-Konto fest.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: newPasswordController,
                  obscureText: obscureNew,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Neues Passwort',
                    suffixIcon: IconButton(
                      icon: Icon(obscureNew ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => obscureNew = !obscureNew),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmPasswordController,
                  obscureText: obscureConfirm,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Passwort bestätigen',
                    suffixIcon: IconButton(
                      icon: Icon(obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => obscureConfirm = !obscureConfirm),
                    ),
                  ),
                  onSubmitted: (_) => submitting ? null : _submit(),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 16),
                  _MessageBox(icon: Icons.error_outline, color: Colors.redAccent, message: errorMessage!),
                ],
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: submitting ? null : _submit,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Passwort speichern'),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: submitting ? null : _cancel,
                  child: const Text('Abbrechen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
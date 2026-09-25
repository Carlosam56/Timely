part of '../main.dart';

class FriendProfilePage extends StatefulWidget {
  final FriendRequest friendRequest;

  const FriendProfilePage({super.key, required this.friendRequest});

  @override
  State<FriendProfilePage> createState() => _FriendProfilePageState();
}

class _FriendProfilePageState extends State<FriendProfilePage> {
  bool removing = false;
  String? errorMessage;

  UserProfile get friend => widget.friendRequest.otherProfile;

  Future<void> _removeFriend() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Freund entfernen?'),
        content: Text(
          '${friend.displayName} wird aus deiner Freundesliste entfernt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      removing = true;
      errorMessage = null;
    });

    try {
      await FriendService.removeFriend(widget.friendRequest.id);

      if (!mounted) return;

      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        removing = false;
        errorMessage = _cleanError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Freund entfernen',
            onPressed: removing ? null : _removeFriend,
            icon: const Icon(Icons.person_remove_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 56,
                  backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  backgroundImage: friend.avatarUrl != null
                      ? NetworkImage(friend.avatarUrl!)
                      : null,
                  child: friend.avatarUrl != null
                      ? null
                      : Text(
                          friend.displayName.isEmpty
                              ? '?'
                              : friend.displayName.characters.first.toUpperCase(),
                          style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
                        ),
                ),
                const SizedBox(height: 20),
                Text(
                  friend.displayName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '@${friend.username}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                if (friend.bio.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    friend.bio,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
                    ),
                  ),
                ],
                if (errorMessage != null) ...[
                  const SizedBox(height: 16),
                  _MessageBox(
                    icon: Icons.error_outline,
                    color: Colors.redAccent,
                    message: errorMessage!,
                  ),
                ],
                const SizedBox(height: 32),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                    textStyle: const TextStyle(fontSize: 16),
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FriendTimetablePage(friend: friend),
                    ),
                  ),
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: const Text('Sein/Ihr Stundenplan'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows a friend's shared timetable for the current week, with a
/// "Vergleiche" toggle that highlights lessons shared with the signed-in
/// user's own current-week timetable in green.
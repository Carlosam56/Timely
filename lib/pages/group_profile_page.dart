part of '../main.dart';

class GroupProfilePage extends StatefulWidget {
  final FriendGroup group;
  final UserProfile myProfile;

  const GroupProfilePage({super.key, required this.group, required this.myProfile});

  @override
  State<GroupProfilePage> createState() => _GroupProfilePageState();
}

class _GroupProfilePageState extends State<GroupProfilePage> {
  bool leavingOrDeleting = false;
  bool updating = false;
  String? errorMessage;

  // Local copy so a rename / new members show up here immediately.
  late FriendGroup _group = widget.group;

  FriendGroup get group => _group;
  bool get isOwner => group.ownerId == widget.myProfile.id;
  bool get busy => leavingOrDeleting || updating;

  Future<void> _rename() async {
    final controller = TextEditingController(text: group.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gruppe umbenennen'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Gruppenname'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == group.name) return;

    setState(() {
      updating = true;
      errorMessage = null;
    });

    try {
      // Groups without a picture show the initial of their name; keep that
      // in sync (but leave custom emoji / pictures alone).
      final oldInitial = group.name.isEmpty ? '' : group.name[0].toUpperCase();
      final usesInitial = group.avatarUrl == null && group.avatarEmoji == oldInitial;
      final newEmoji = usesInitial ? newName[0].toUpperCase() : null;

      await GroupService.renameGroup(
        groupId: group.id,
        name: newName,
        avatarEmoji: newEmoji,
      );

      if (!mounted) return;
      setState(() {
        _group = _group.copyWith(name: newName, avatarEmoji: newEmoji);
        updating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        updating = false;
        errorMessage = _cleanError(e);
      });
    }
  }

  Future<void> _removeMember(UserProfile member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mitglied entfernen'),
        content: Text('${member.displayName} aus "${group.name}" entfernen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      updating = true;
      errorMessage = null;
    });

    try {
      await GroupService.removeMember(
        groupId: group.id,
        userId: member.id,
        ownerId: group.ownerId,
      );

      if (!mounted) return;
      setState(() {
        _group = _group.copyWith(
          members: _group.members.where((m) => m.id != member.id).toList(),
        );
        updating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        updating = false;
        errorMessage = _cleanError(e);
      });
    }
  }

  Future<void> _addMembers() async {
    setState(() {
      updating = true;
      errorMessage = null;
    });

    try {
      final data = await FriendService.loadFriendData();
      final memberIds = group.members.map((m) => m.id).toSet();
      final candidates = data.accepted
          .where((request) => !memberIds.contains(request.otherProfile.id))
          .toList();

      if (!mounted) return;
      setState(() => updating = false);

      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Alle deine Freunde sind schon in dieser Gruppe.'),
          ),
        );
        return;
      }

      final selected = await Navigator.push<List<String>>(
        context,
        MaterialPageRoute(
          builder: (_) => AddGroupMembersPage(
            groupName: group.name,
            candidates: candidates,
          ),
        ),
      );

      if (selected == null || selected.isEmpty || !mounted) return;

      setState(() => updating = true);

      await GroupService.addMembers(groupId: group.id, userIds: selected);

      final added = candidates
          .where((request) => selected.contains(request.otherProfile.id))
          .map((request) => request.otherProfile)
          .toList();

      if (!mounted) return;
      setState(() {
        _group = _group.copyWith(members: [..._group.members, ...added]);
        updating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        updating = false;
        errorMessage = _cleanError(e);
      });
    }
  }

  Future<void> _leaveOrDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isOwner ? 'Gruppe löschen' : 'Gruppe verlassen'),
        content: Text(
          isOwner
              ? '"${group.name}" wird für alle Mitglieder gelöscht.'
              : 'Du verlässt "${group.name}".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(isOwner ? 'Löschen' : 'Verlassen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      leavingOrDeleting = true;
      errorMessage = null;
    });

    try {
      if (isOwner) {
        await GroupService.deleteGroup(group.id);
      } else {
        await GroupService.leaveGroup(group.id, widget.myProfile.id);
      }
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        leavingOrDeleting = false;
        errorMessage = _cleanError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (isOwner)
            IconButton(
              tooltip: 'Gruppe umbenennen',
              onPressed: busy ? null : _rename,
              icon: const Icon(Icons.edit_outlined),
            ),
          IconButton(
            tooltip: isOwner ? 'Gruppe löschen' : 'Gruppe verlassen',
            onPressed: busy ? null : _leaveOrDelete,
            icon: Icon(isOwner ? Icons.delete_outline : Icons.logout),
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
                  backgroundColor: Color(group.avatarColor).withValues(alpha: 0.22),
                  backgroundImage:
                      group.avatarUrl != null ? NetworkImage(group.avatarUrl!) : null,
                  child: group.avatarUrl == null
                      ? Text(group.avatarEmoji, style: const TextStyle(fontSize: 40))
                      : null,
                ),
                const SizedBox(height: 20),
                Text(
                  group.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '${group.members.length} Mitglieder',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 16),
                  _MessageBox(
                    icon: Icons.error_outline,
                    color: Colors.redAccent,
                    message: errorMessage!,
                  ),
                ],
                const SizedBox(height: 28),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                    textStyle: const TextStyle(fontSize: 16),
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GroupTimetablePage(
                        group: group,
                        myProfile: widget.myProfile,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: const Text('Stundenplan vergleichen'),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Mitglieder',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    if (isOwner)
                      TextButton.icon(
                        onPressed: busy ? null : _addMembers,
                        icon: updating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.person_add_alt_1, size: 18),
                        label: const Text('Hinzufügen'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                ...group.members.map((member) {
                  final isMe = member.id == widget.myProfile.id;
                  final isGroupOwner = member.id == group.ownerId;
                  final removable = isOwner && !isMe && !isGroupOwner;
                  return _PersonTile(
                    profile: member,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isMe)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              '(Ich)',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        if (isGroupOwner)
                          Icon(Icons.star_rounded, size: 20, color: Colors.amber.shade600),
                        if (removable)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Entfernen',
                            onPressed: busy ? null : () => _removeMember(member),
                            icon: Icon(
                              Icons.person_remove_outlined,
                              size: 20,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lets the group owner pick which of their friends to add to a group.
/// Pops with the selected user ids (or null if cancelled).
part of '../main.dart';

const List<int> _groupAvatarColors = [
  0xFF8B5CF6,
  0xFFEF4444,
  0xFFF59E0B,
  0xFF10B981,
  0xFF3B82F6,
  0xFFEC4899,
  0xFF14B8A6,
  0xFF6366F1,
];

/// Screen for creating a new group: name, an emoji/color "profile picture",
/// and which friends belong to it. Reached via the two-people icon next to
/// the add-friend button on [FriendsPage].

class CreateGroupPage extends StatefulWidget {
  final List<FriendRequest> friends;

  const CreateGroupPage({super.key, required this.friends});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final nameController = TextEditingController();
  final Set<String> selectedFriendIds = {};
  Uint8List? pickedImageBytes;
  bool saving = false;
  bool pickingImage = false;
  String? errorMessage;

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    setState(() => pickingImage = true);
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 800,
        maxHeight: 800,
      );
      if (file == null) return;

      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() => pickedImageBytes = bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() => errorMessage = 'Foto konnte nicht ausgewählt werden.');
    } finally {
      if (mounted) setState(() => pickingImage = false);
    }
  }

  Future<void> _save() async {
    final name = nameController.text.trim();

    if (name.isEmpty) {
      setState(() => errorMessage = 'Bitte gib einen Namen für die Gruppe ein.');
      return;
    }
    if (selectedFriendIds.isEmpty) {
      setState(() => errorMessage = 'Wähle mindestens einen Freund aus.');
      return;
    }

    setState(() {
      saving = true;
      errorMessage = null;
    });

    // No picture was uploaded: fall back to a colored circle with the
    // group's initial, derived from the name so it stays consistent.
    final fallbackEmoji = name[0].toUpperCase();
    final fallbackColor = _groupAvatarColors[name.hashCode.abs() % _groupAvatarColors.length];

    try {
      await GroupService.createGroup(
        name: name,
        avatarEmoji: fallbackEmoji,
        avatarColor: fallbackColor,
        memberIds: selectedFriendIds.toList(),
        avatarBytes: pickedImageBytes,
      );

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      debugPrint('FULL ERROR: $e');
      if (!mounted) return;
      setState(() {
        saving = false;
        errorMessage = _cleanError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gruppe erstellen')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: GestureDetector(
                onTap: pickingImage ? null : _pickImage,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 44,
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                      backgroundImage: pickedImageBytes != null
                          ? MemoryImage(pickedImageBytes!)
                          : null,
                      child: pickedImageBytes == null
                          ? (pickingImage
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  Icons.add_a_photo_outlined,
                                  size: 30,
                                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                                ))
                          : null,
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).colorScheme.primary,
                          border: Border.all(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            width: 2,
                          ),
                        ),
                        child: const Icon(Icons.edit, size: 14, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: pickingImage ? null : _pickImage,
                child: Text(pickedImageBytes == null ? 'Foto hinzufügen' : 'Foto ändern'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Gruppenname',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            const _SectionTitle(title: 'Mitglieder'),
            ...widget.friends.map((request) {
              final profile = request.otherProfile;
              final isSelected = selectedFriendIds.contains(profile.id);
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  setState(() {
                    if (isSelected) {
                      selectedFriendIds.remove(profile.id);
                    } else {
                      selectedFriendIds.add(profile.id);
                    }
                  });
                },
                child: _PersonTile(
                  profile: profile,
                  trailing: Checkbox(
                    value: isSelected,
                    onChanged: (checked) {
                      setState(() {
                        if (checked == true) {
                          selectedFriendIds.add(profile.id);
                        } else {
                          selectedFriendIds.remove(profile.id);
                        }
                      });
                    },
                  ),
                ),
              );
            }),
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              _MessageBox(
                icon: Icons.error_outline,
                color: Colors.redAccent,
                message: errorMessage!,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: saving ? null : _save,
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Gruppe erstellen'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows a group: pick which members (including yourself) to compare, then
/// see, period by period, where everyone selected has something in common
/// (green - free or the same lesson for all of them) or only some of them do
/// (yellow - tap it to see who).
/// Profile-style landing page for a group, reached by tapping it in the
/// "Gruppen" list on [FriendsPage]. Mirrors [FriendProfilePage]: avatar,
/// name, member list, and a button into the actual timetable comparison.
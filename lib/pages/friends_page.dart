part of '../main.dart';

class FriendsPage extends StatefulWidget {
  final UserProfile currentProfile;

  /// Open incoming friend requests; shown as a badge on the add-friend icon.
  final int pendingRequests;

  /// Called when requests may have changed (screen closed, pull to refresh),
  /// so the parent can update its own badge count.
  final VoidCallback? onRequestsChanged;

  const FriendsPage({
    super.key,
    required this.currentProfile,
    this.pendingRequests = 0,
    this.onRequestsChanged,
  });

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  List<FriendRequest> acceptedFriends = [];
  List<FriendGroup> groups = [];
  bool loading = true;
  bool groupsLoading = true;
  String? errorMessage;
  String? groupsError;
  bool showGroups = false;

  @override
  void initState() {
    super.initState();
    loadFriends();
    loadGroups();
  }

  Future<void> loadFriends() async {
    setState(() {
      loading = true;
      errorMessage = null;
    });

    try {
      final data = await FriendService.loadFriendData();

      if (!mounted) return;

      setState(() {
        acceptedFriends = data.accepted;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        errorMessage = _cleanError(e);
        loading = false;
      });
    }
  }

  Future<void> loadGroups() async {
    setState(() {
      groupsLoading = true;
      groupsError = null;
    });

    try {
      final data = await GroupService.loadGroups();

      if (!mounted) return;

      setState(() {
        groups = data;
        groupsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        groupsError = _cleanError(e);
        groupsLoading = false;
      });
    }
  }

  Future<void> _openAddFriends() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FriendRequestsPage()),
    );

    // Requests may have been accepted/sent while that screen was open.
    loadFriends();
    widget.onRequestsChanged?.call();
  }

  Future<void> _openFriendProfile(FriendRequest request) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FriendProfilePage(friendRequest: request),
      ),
    );

    // The friend may have been removed from that screen.
    loadFriends();
  }

  Future<void> _openCreateGroup() async {
    if (acceptedFriends.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Du brauchst mindestens einen Freund, um eine Gruppe zu erstellen.',
          ),
        ),
      );
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CreateGroupPage(friends: acceptedFriends)),
    );

    loadGroups();
  }

  Future<void> _openGroup(FriendGroup group) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupProfilePage(group: group, myProfile: widget.currentProfile),
      ),
    );

    // The group may have been renamed/left/deleted while that screen was open.
    loadGroups();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async {
          widget.onRequestsChanged?.call();
          await Future.wait([loadFriends(), loadGroups()]);
        },
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    _FriendsTab(
                      label: 'Freunde',
                      selected: !showGroups,
                      onTap: () => setState(() => showGroups = false),
                    ),
                    const SizedBox(width: 12),
                    _FriendsTab(
                      label: 'Gruppen',
                      selected: showGroups,
                      onTap: () => setState(() => showGroups = true),
                    ),
                  ],
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.85, end: 1).animate(animation),
                      child: child,
                    ),
                  ),
                  child: showGroups
                      ? IconButton.filledTonal(
                          key: const ValueKey('create-group'),
                          tooltip: 'Gruppe erstellen',
                          onPressed: _openCreateGroup,
                          icon: const Icon(Icons.group_add),
                        )
                      : IconButton.filledTonal(
                          key: const ValueKey('add-friends'),
                          tooltip: 'Freunde hinzufügen',
                          onPressed: _openAddFriends,
                          icon: Badge(
                            isLabelVisible: widget.pendingRequests > 0,
                            label: Text(_badgeText(widget.pendingRequests)),
                            child: const Icon(Icons.person_add_alt_1),
                          ),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (!showGroups) ...[
              if (errorMessage != null) ...[
                _MessageBox(
                  icon: Icons.error_outline,
                  color: Colors.redAccent,
                  message: errorMessage!,
                ),
                const SizedBox(height: 14),
              ],
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (acceptedFriends.isEmpty)
                const _EmptyLine(
                  text: 'Noch keine Freunde. Füge welche über das Symbol oben rechts hinzu.',
                )
              else
                ...acceptedFriends.map(
                  (request) => InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _openFriendProfile(request),
                    child: _PersonTile(
                      profile: request.otherProfile,
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ),
                ),
            ] else ...[
              if (groupsError != null) ...[
                _MessageBox(
                  icon: Icons.error_outline,
                  color: Colors.redAccent,
                  message: groupsError!,
                ),
                const SizedBox(height: 14),
              ],
              if (groupsLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (groups.isEmpty)
                const _EmptyLine(
                  text: 'Noch keine Gruppen. Erstelle eine über das Symbol oben rechts.',
                )
              else
                ...groups.map(
                  (group) => InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _openGroup(group),
                    child: _GroupTile(group: group),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One of the two section titles on [FriendsPage]. Size and color animate
/// smoothly between the selected (big, accent) and unselected (small, dim)
/// look instead of jumping.

class _FriendsTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FriendsTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        style: TextStyle(
          fontSize: selected ? 28 : 20,
          fontWeight: FontWeight.bold,
          color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.35),
        ),
        child: Text(label),
      ),
    );
  }
}

/// A single row in the "Gruppen" list on [FriendsPage].

class _GroupTile extends StatelessWidget {
  final FriendGroup group;

  const _GroupTile({required this.group});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: Color(group.avatarColor).withValues(alpha: 0.22),
            backgroundImage:
                group.avatarUrl != null ? NetworkImage(group.avatarUrl!) : null,
            child: group.avatarUrl == null
                ? Text(group.avatarEmoji, style: const TextStyle(fontSize: 18))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${group.members.length} Mitglieder',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
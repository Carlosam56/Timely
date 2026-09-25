part of '../main.dart';

class FriendRequestsPage extends StatefulWidget {
  const FriendRequestsPage({super.key});

  @override
  State<FriendRequestsPage> createState() => _FriendRequestsPageState();
}

class _FriendRequestsPageState extends State<FriendRequestsPage> {
  final searchController = TextEditingController();
  List<UserProfile> searchResults = [];
  List<FriendRequest> incomingRequests = [];
  List<FriendRequest> outgoingRequests = [];
  List<FriendRequest> acceptedFriends = [];
  bool loading = true;
  bool searching = false;
  String? errorMessage;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    loadFriends();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    searchController.dispose();
    super.dispose();
  }

  void onSearchTextChanged(String text) {
    _searchDebounce?.cancel();

    if (text.trim().length < 2) {
      setState(() {
        searchResults = [];
      });
      return;
    }

    // Wait a moment after the user stops typing before hitting the
    // database, so suggestions update live without a request per keystroke.
    _searchDebounce = Timer(const Duration(milliseconds: 350), searchUsers);
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
        incomingRequests = data.incoming;
        outgoingRequests = data.outgoing;
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

  Future<void> searchUsers() async {
    final text = searchController.text.trim();

    if (text.length < 2) {
      setState(() {
        searchResults = [];
      });
      return;
    }

    setState(() {
      searching = true;
      errorMessage = null;
    });

    try {
      final results = await FriendService.searchProfiles(text);

      if (!mounted) return;

      setState(() {
        searchResults = results;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        errorMessage = _cleanError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          searching = false;
        });
      }
    }
  }

  Future<void> runFriendAction(Future<void> Function() action) async {
    setState(() {
      errorMessage = null;
    });

    try {
      await action();
      await loadFriends();
      await searchUsers();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        errorMessage = _cleanError(e);
      });
    }
  }

  bool hasActiveRelationshipWith(String profileId) {
    return incomingRequests.any(
          (request) => request.otherProfile.id == profileId,
        ) ||
        outgoingRequests.any(
          (request) => request.otherProfile.id == profileId,
        ) ||
        acceptedFriends.any((request) => request.otherProfile.id == profileId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Freunde hinzufügen')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: loadFriends,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextField(
                controller: searchController,
                onChanged: onSearchTextChanged,
                onSubmitted: (_) => searchUsers(),
                decoration: InputDecoration(
                  labelText: 'Benutzer suchen',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          onPressed: searchUsers,
                          icon: const Icon(Icons.arrow_forward),
                        ),
                ),
              ),
              const SizedBox(height: 14),
              if (errorMessage != null) ...[
                _MessageBox(
                  icon: Icons.error_outline,
                  color: Colors.redAccent,
                  message: errorMessage!,
                ),
                const SizedBox(height: 14),
              ],
              if (searchResults.isNotEmpty) ...[
                const _SectionTitle(title: 'Suchergebnisse'),
                ...searchResults.map((profile) {
                  final blocked = hasActiveRelationshipWith(profile.id);

                  return _PersonTile(
                    profile: profile,
                    trailing: blocked
                        ? Text(
                            'Bereits verbunden',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                          )
                        : FilledButton.icon(
                            onPressed: () => runFriendAction(
                              () => FriendService.sendRequest(profile.id),
                            ),
                            icon: const Icon(Icons.person_add_alt_1),
                            label: const Text('Anfragen'),
                          ),
                  );
                }),
                const SizedBox(height: 20),
              ],
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                const _SectionTitle(title: 'Eingehende Anfragen'),
                if (incomingRequests.isEmpty)
                  const _EmptyLine(text: 'Keine offenen Anfragen.')
                else
                  ...incomingRequests.map(
                    (request) => _PersonTile(
                      profile: request.otherProfile,
                      trailing: Wrap(
                        spacing: 8,
                        children: [
                          IconButton.filled(
                            tooltip: 'Annehmen',
                            onPressed: () => runFriendAction(
                              () => FriendService.acceptRequest(request.id),
                            ),
                            icon: const Icon(Icons.check),
                          ),
                          IconButton.outlined(
                            tooltip: 'Ablehnen',
                            onPressed: () => runFriendAction(
                              () => FriendService.declineRequest(request.id),
                            ),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                const _SectionTitle(title: 'Ausgehende Anfragen'),
                if (outgoingRequests.isEmpty)
                  const _EmptyLine(text: 'Keine gesendeten Anfragen.')
                else
                  ...outgoingRequests.map(
                    (request) => _PersonTile(
                      profile: request.otherProfile,
                      trailing: TextButton.icon(
                        onPressed: () => runFriendAction(
                          () => FriendService.cancelRequest(request.id),
                        ),
                        icon: const Icon(Icons.undo),
                        label: const Text('Zurückziehen'),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A friend's profile: avatar, name, and the entry point into their
/// (shared) timetable.
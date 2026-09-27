part of '../main.dart';

class WebUntisService {
  static const _timeout = Duration(seconds: 20);

  // Browsers block direct requests to *.webuntis.com because WebUntis
  // doesn't send an Access-Control-Allow-Origin header - so on web builds
  // every request is routed through Timely's own Vercel proxy
  // (api/webuntis-proxy.js) instead, which isn't subject to that
  // restriction. Native builds (no browser involved) call WebUntis
  // directly, unchanged.
  static Uri _proxied(Uri realUrl) {
    if (!kIsWeb) return realUrl;
    return Uri(path: '/api/webuntis-proxy', queryParameters: {'url': realUrl.toString()});
  }

  static Future<WebUntisSession> authenticate({
    required String school,
    required String username,
    required String password,
  }) async {
    final baseUrl = 'https://$school.webuntis.com';
    final url = Uri.parse('$baseUrl/WebUntis/jsonrpc.do?school=$school');

    final requestBody = {
      'id': DateTime.now().millisecondsSinceEpoch,
      'method': 'authenticate',
      'params': {'user': username, 'password': password, 'client': 'Timely'},
      'jsonrpc': '2.0',
    };

    final response = await http.post(
      _proxied(url),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(requestBody),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('WebUntis antwortete mit HTTP ${response.statusCode}.');
    }

    final data = jsonDecode(response.body);

    if (data['error'] != null) {
      throw Exception(
        data['error']['message']?.toString() ?? 'Anmeldung fehlgeschlagen.',
      );
    }

    final result = data['result'];

    if (result == null) {
      throw Exception('Ungültige Antwort von WebUntis.');
    }

    final sessionId = result['sessionId']?.toString();

    if (sessionId == null || sessionId.isEmpty) {
      throw Exception('Keine Session-ID erhalten.');
    }

    final personId = _toInt(result['personId']);
    final personType = _toInt(result['personType']);

    if (personId == null || personType == null) {
      throw Exception('Benutzerinformationen fehlen.');
    }

    final session = WebUntisSession(
      sessionId: sessionId,
      personId: personId,
      personType: personType,
    );
    unawaited(_saveUntisPersonToCache(session));
    return session;
  }

  static Future<Map<String, dynamic>> request({
    required String school,
    required String sessionId,
    required String method,
    required Map<String, dynamic> params,
  }) async {
    final baseUrl = 'https://$school.webuntis.com';
    final url = Uri.parse(
      '$baseUrl/WebUntis/jsonrpc.do;jsessionid=$sessionId?school=$school',
    );

    final requestBody = {
      'id': DateTime.now().millisecondsSinceEpoch,
      'method': method,
      'params': params,
      'jsonrpc': '2.0',
    };

    final response = await http.post(
      _proxied(url),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(requestBody),
    ).timeout(_timeout);

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw WebUntisSessionExpired();
    }

    if (response.statusCode != 200) {
      throw Exception('WebUntis antwortete mit HTTP ${response.statusCode}.');
    }

    final data = jsonDecode(response.body);

    if (data['error'] != null) {
      // -8520 = "not authenticated": the session expired.
      final code = _toInt(data['error']['code']);
      final message = data['error']['message']?.toString().toLowerCase() ?? '';
      if (code == -8520 || message.contains('not authenticated')) {
        throw WebUntisSessionExpired();
      }
      throw Exception(
        data['error']['message']?.toString() ?? 'WebUntis-Fehler.',
      );
    }

    return Map<String, dynamic>.from(data);
  }
}

class ProfileService {
  static Future<UserProfile> loadCurrentProfile() async {
    final user = supabase.auth.currentUser;

    if (user == null) {
      throw Exception('Keine aktive Timely-Sitzung.');
    }

    final row = await supabase
        .from('profiles')
        .select()
        .eq('id', user.id)
        .maybeSingle()
        .timeout(_supabaseTimeout);

    if (row != null) {
      final profile = UserProfile.fromJson(row);
      return _withWebUntisHint(profile);
    }

    final metadata = user.userMetadata ?? {};
    final emailName = _normalizeUsername(user.email?.split('@').first ?? 'user');
    final metadataUsername = metadata['username']?.toString().trim();
    final metadataFullName = metadata['full_name']?.toString().trim();
    final username = (metadataUsername != null && metadataUsername.isNotEmpty)
        ? metadataUsername
        : emailName;
    final fullName = (metadataFullName != null && metadataFullName.isNotEmpty)
        ? metadataFullName
        : username;

    await upsertCurrentProfile(
      username: username,
      fullName: fullName,
      termsAcceptedAt: await _takePendingTermsAcceptedAt(),
    );

    final created = await supabase
        .from('profiles')
        .select()
        .eq('id', user.id)
        .single()
        .timeout(_supabaseTimeout);

    return _withWebUntisHint(UserProfile.fromJson(created));
  }

  static Future<UserProfile> _withWebUntisHint(UserProfile profile) async {
    final row = await supabase
        .from('webuntis_connections')
        .select()
        .eq('user_id', profile.id)
        .maybeSingle()
        .timeout(_supabaseTimeout);

    if (row == null) {
      return profile;
    }

    return profile.copyWith(
      webUntisSchool: row['webuntis_school']?.toString(),
      webUntisUsername: row['webuntis_username']?.toString(),
    );
  }

  static Future<void> upsertCurrentProfile({
    required String username,
    required String fullName,
    String? bio,
    DateTime? termsAcceptedAt,
  }) async {
    final user = supabase.auth.currentUser;

    if (user == null) {
      throw Exception('Keine aktive Timely-Sitzung.');
    }

    await supabase.from('profiles').upsert({
      'id': user.id,
      'username': username,
      'full_name': fullName,
      'bio': ?bio,
      'terms_accepted_at': ?termsAcceptedAt?.toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).timeout(_supabaseTimeout);
  }

  /// Uploads a new profile picture (JPEG, overwriting any previous one) and
  /// points `profiles.avatar_url` at it. Returns the public URL.
  static Future<String> uploadAvatar(Uint8List bytes) async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      throw Exception('Keine aktive Timely-Sitzung.');
    }

    final path = '${user.id}.jpg';
    await supabase.storage
        .from('avatars')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'),
        )
        .timeout(_supabaseTimeout);

    // A fresh upload keeps the same path, so cached copies (in the app, in
    // Supabase's CDN) need cache-busting or the old picture keeps showing.
    final publicUrl =
        '${supabase.storage.from('avatars').getPublicUrl(path)}?v=${DateTime.now().millisecondsSinceEpoch}';

    await supabase
        .from('profiles')
        .update({'avatar_url': publicUrl})
        .eq('id', user.id)
        .timeout(_supabaseTimeout);

    return publicUrl;
  }

  static Future<void> removeAvatar() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      throw Exception('Keine aktive Timely-Sitzung.');
    }

    await supabase
        .from('profiles')
        .update({'avatar_url': null})
        .eq('id', user.id)
        .timeout(_supabaseTimeout);

    try {
      await supabase.storage
          .from('avatars')
          .remove(['${user.id}.jpg'])
          .timeout(_supabaseTimeout);
    } catch (_) {
      // The row is already updated; a leftover file in storage is harmless.
    }
  }

  static Future<void> saveWebUntisHint({
    required String school,
    required String username,
  }) async {
    final user = supabase.auth.currentUser;

    if (user == null) {
      throw Exception('Keine aktive Timely-Sitzung.');
    }

    await supabase.from('webuntis_connections').upsert({
      'user_id': user.id,
      'webuntis_school': school,
      'webuntis_username': username,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).timeout(_supabaseTimeout);
  }
}

class FriendService {
  static Future<List<UserProfile>> searchProfiles(String text) async {
    final response = await supabase
        .rpc('search_profiles', params: {'search_text': text})
        .timeout(_supabaseTimeout);

    final rows = response as List<dynamic>;

    return rows
        .map(
          (row) => UserProfile.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  static Future<FriendData> loadFriendData() async {
    final currentUserId = supabase.auth.currentUser?.id;

    if (currentUserId == null) {
      throw Exception('Keine aktive Timely-Sitzung.');
    }

    final response = await supabase
        .from('friend_requests')
        .select(
          'id, requester_id, addressee_id, status, created_at, updated_at, '
          'requester:profiles!friend_requests_requester_id_fkey(id, username, full_name, bio, avatar_url, school_id), '
          'addressee:profiles!friend_requests_addressee_id_fkey(id, username, full_name, bio, avatar_url, school_id)',
        )
        .or('requester_id.eq.$currentUserId,addressee_id.eq.$currentUserId')
        .inFilter('status', ['pending', 'accepted'])
        .order('updated_at', ascending: false)
        .timeout(_supabaseTimeout);

    final incoming = <FriendRequest>[];
    final outgoing = <FriendRequest>[];
    final accepted = <FriendRequest>[];

    for (final item in response as List<dynamic>) {
      final request = FriendRequest.fromJson(
        Map<String, dynamic>.from(item as Map),
        currentUserId,
      );

      if (request.status == 'accepted') {
        accepted.add(request);
      } else if (request.addresseeId == currentUserId) {
        incoming.add(request);
      } else {
        outgoing.add(request);
      }
    }

    return FriendData(
      incoming: incoming,
      outgoing: outgoing,
      accepted: accepted,
    );
  }

  /// How many friend requests are waiting for the current user to answer.
  static Future<int> countIncomingPending() async {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return 0;

    final rows = await supabase
        .from('friend_requests')
        .select('id')
        .eq('addressee_id', currentUserId)
        .eq('status', 'pending')
        .timeout(_supabaseTimeout);

    return (rows as List<dynamic>).length;
  }

  static Future<void> sendRequest(String addresseeId) async {
    await supabase
        .from('friend_requests')
        .insert({'addressee_id': addresseeId})
        .timeout(_supabaseTimeout);
  }

  static Future<void> acceptRequest(String requestId) async {
    await supabase
        .from('friend_requests')
        .update({
          'status': 'accepted',
          'responded_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', requestId)
        .eq('status', 'pending')
        .timeout(_supabaseTimeout);
  }

  static Future<void> declineRequest(String requestId) async {
    await supabase
        .from('friend_requests')
        .update({
          'status': 'declined',
          'responded_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', requestId)
        .eq('status', 'pending')
        .timeout(_supabaseTimeout);
  }

  static Future<void> cancelRequest(String requestId) async {
    await supabase
        .from('friend_requests')
        .update({'status': 'cancelled'})
        .eq('id', requestId)
        .eq('status', 'pending')
        .timeout(_supabaseTimeout);
  }

  static Future<void> removeFriend(String requestId) async {
    await supabase
        .from('friend_requests')
        .update({'status': 'removed'})
        .eq('id', requestId)
        .eq('status', 'accepted')
        .timeout(_supabaseTimeout);
  }
}

class GroupService {
  static Future<List<FriendGroup>> loadGroups() async {
    final currentUserId = supabase.auth.currentUser?.id;

    if (currentUserId == null) {
      throw Exception('Keine aktive Timely-Sitzung.');
    }

    final memberRows = await supabase
        .from('group_members')
        .select('group_id')
        .eq('user_id', currentUserId)
        .timeout(_supabaseTimeout);

    final groupIds = (memberRows as List<dynamic>)
        .map((row) => (row as Map)['group_id'].toString())
        .toList();

    if (groupIds.isEmpty) return [];

    final groupRows = await supabase
        .from('groups')
        .select('id, name, owner_id, avatar_emoji, avatar_color, avatar_url, created_at')
        .inFilter('id', groupIds)
        .order('created_at')
        .timeout(_supabaseTimeout);

    final allMemberRows = await supabase
        .from('group_members')
        .select(
          'group_id, profile:profiles!group_members_user_id_fkey(id, username, full_name, bio, avatar_url, school_id)',
        )
        .inFilter('group_id', groupIds)
        .timeout(_supabaseTimeout);

    final membersByGroup = <String, List<UserProfile>>{};
    for (final item in allMemberRows as List<dynamic>) {
      final row = Map<String, dynamic>.from(item as Map);
      final groupId = row['group_id'].toString();
      final profile = UserProfile.fromJson(
        Map<String, dynamic>.from(row['profile'] as Map),
      );
      membersByGroup.putIfAbsent(groupId, () => []).add(profile);
    }

    return (groupRows as List<dynamic>).map((item) {
      final row = Map<String, dynamic>.from(item as Map);
      final id = row['id'].toString();
      return FriendGroup.fromJson(row, membersByGroup[id] ?? []);
    }).toList();
  }

  static Future<void> createGroup({
    required String name,
    required String avatarEmoji,
    required int avatarColor,
    required List<String> memberIds,
    Uint8List? avatarBytes,
  }) async {
    final currentUserId = supabase.auth.currentUser?.id;

    if (currentUserId == null) {
      throw Exception('Keine aktive Timely-Sitzung.');
    }

    final inserted = await supabase
        .from('groups')
        .insert({
          'owner_id': currentUserId,
          'name': name,
          'avatar_emoji': avatarEmoji,
          'avatar_color': avatarColor,
        })
        .select()
        .single()
        .timeout(_supabaseTimeout);

    final groupId = inserted['id'].toString();

    if (avatarBytes != null) {
      // The group itself was created successfully at this point, so a
      // failed picture upload shouldn't block the whole flow - it just
      // means the group keeps its colored-initial fallback for now.
      try {
        final path = '$groupId.jpg';
        await supabase.storage
            .from('group-avatars')
            .uploadBinary(
              path,
              avatarBytes,
              fileOptions: const FileOptions(
                upsert: true,
                contentType: 'image/jpeg',
              ),
            )
            .timeout(_supabaseTimeout);
        final publicUrl = supabase.storage.from('group-avatars').getPublicUrl(path);
        await supabase
            .from('groups')
            .update({'avatar_url': publicUrl})
            .eq('id', groupId)
            .timeout(_supabaseTimeout);
      } catch (_) {
        // Ignore - see comment above.
      }
    }

    final allMemberIds = {currentUserId, ...memberIds}.toList();

    await supabase
        .from('group_members')
        .insert([
          for (final id in allMemberIds) {'group_id': groupId, 'user_id': id},
        ])
        .timeout(_supabaseTimeout);
  }

  /// Renames a group. If the group's avatar is just the colored initial of
  /// its old name, pass the new initial as [avatarEmoji] so it stays in sync.
  static Future<void> renameGroup({
    required String groupId,
    required String name,
    String? avatarEmoji,
  }) async {
    final rows = await supabase
        .from('groups')
        .update({
          'name': name,
          'avatar_emoji': ?avatarEmoji,
        })
        .eq('id', groupId)
        .select('id')
        .timeout(_supabaseTimeout);

    // A blocked update (row-level security) doesn't throw - it just matches
    // no rows - so check for that instead of pretending it worked.
    if ((rows as List<dynamic>).isEmpty) {
      throw Exception('Die Gruppe konnte nicht umbenannt werden (keine Berechtigung).');
    }
  }

  static Future<void> addMembers({
    required String groupId,
    required List<String> userIds,
  }) async {
    if (userIds.isEmpty) return;

    await supabase
        .from('group_members')
        .insert([
          for (final id in userIds) {'group_id': groupId, 'user_id': id},
        ])
        .timeout(_supabaseTimeout);
  }

  static Future<void> deleteGroup(String groupId) async {
    await supabase
        .from('groups')
        .delete()
        .eq('id', groupId)
        .timeout(_supabaseTimeout);
  }

  static Future<void> leaveGroup(String groupId, String userId) async {
    await supabase
        .from('group_members')
        .delete()
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .timeout(_supabaseTimeout);
  }

  /// Removes one member from a group without them leaving on their own -
  /// used by the group owner. Removing the owner isn't allowed here; delete
  /// the group instead.
  static Future<void> removeMember({
    required String groupId,
    required String userId,
    required String ownerId,
  }) async {
    if (userId == ownerId) {
      throw Exception('Der Ersteller kann nicht entfernt werden.');
    }
    await supabase
        .from('group_members')
        .delete()
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .timeout(_supabaseTimeout);
  }
}

/// Uploads/downloads a "resolved" (subject/teacher/room names, not WebUntis
/// IDs) snapshot of the current week's timetable, so that accepted friends
/// can view and compare it without needing each other's WebUntis session.

class TimetableSyncService {
  static Future<void> uploadCurrentWeek({
    required DateTime weekStart,
    required List<Lesson> lessons,
  }) async {
    // Opt-in: without the user's explicit consent nothing leaves the device.
    if (!appShareTimetable.value) return;

    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    try {
      await supabase.from('shared_timetables').upsert({
        'user_id': userId,
        'week_start': _formatIsoDate(weekStart),
        'lessons': lessons.map((lesson) => lesson.toStoredJson()).toList(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).timeout(_supabaseTimeout);
    } catch (_) {
      // Sharing is best-effort - failing to sync shouldn't disrupt the
      // user's own timetable view.
    }
  }

  /// Deletes every timetable week this user has shared. Throws on failure so
  /// callers can tell the user instead of pretending it worked.
  static Future<void> deleteMine() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    await supabase
        .from('shared_timetables')
        .delete()
        .eq('user_id', userId)
        .timeout(_supabaseTimeout);
  }

  static Future<List<Lesson>?> loadWeek({
    required String userId,
    required DateTime weekStart,
  }) async {
    final row = await supabase
        .from('shared_timetables')
        .select('lessons')
        .eq('user_id', userId)
        .eq('week_start', _formatIsoDate(weekStart))
        .maybeSingle()
        .timeout(_supabaseTimeout);

    if (row == null) return null;

    final rawLessons = row['lessons'];
    if (rawLessons is! List) return [];

    return rawLessons
        .whereType<Map>()
        .map((item) => Lesson.fromStoredJson(Map<String, dynamic>.from(item)))
        .toList();
  }
}
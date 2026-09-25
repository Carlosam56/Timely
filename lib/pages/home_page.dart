part of '../main.dart';

class HomePage extends StatefulWidget {
  final UserProfile profile;
  final String school;
  final String username;
  final String sessionId;
  final int personId;
  final int personType;

  const HomePage({
    super.key,
    required this.profile,
    required this.school,
    required this.username,
    required this.sessionId,
    required this.personId,
    required this.personType,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const int _weeksBack = 2;
  static const int _weeksForward = 2;
  static const int _weekPageCount = _weeksBack + _weeksForward + 1;

  int selectedIndex = 0;
  late final PageController weekPageController;
  final _LinkedScrollController _gridScroll = _LinkedScrollController();
  int currentWeekOffset = 0;
  late UserProfile _profile = widget.profile;

  /// Bumped whenever the profile changes so open settings sub-pages (which
  /// are separate routes and never see this State's setState) rebuild.
  final ValueNotifier<int> _settingsRevision = ValueNotifier(0);

  /// Friend requests waiting for an answer; shown as a badge on the Freunde
  /// tab. Refreshed on start, on app resume, on tab change, every minute
  /// while the app is open, and after the requests screen closes.
  int _pendingRequests = 0;
  Timer? _pendingRequestsTimer;

  // Per-week-offset state. Offset 0 is the current week, negative is past,
  // positive is future. We always keep _weeksBack..+_weeksForward loaded.
  final Map<int, Map<DateTime, List<Lesson>>> weekLessons = {};
  final Map<int, bool> weekLoading = {};
  final Map<int, String?> weekErrors = {};
  final Map<int, DateTime> weekCachedAt = {};

  // Current WebUntis session. Starts from the widget values but can be
  // replaced by a silent re-login (expired session, or an offline cold start
  // where sessionId is empty).
  late String _sessionId = widget.sessionId;
  late int _personId = widget.personId;
  late int _personType = widget.personType;
  Future<void>? _reauthFuture;

  // The school's own time grid (see [SchoolSchedule]). [_baseSchedule] is the
  // grid itself; [appSchedule] is that grid widened to cover every loaded
  // lesson.
  SchoolSchedule _baseSchedule = SchoolSchedule.fallback;

  Future<void>? _masterDataFuture;
  bool _subjectsLoaded = false;
  bool _teachersLoaded = false;
  bool _roomsLoaded = false;

  // ID -> name mappings
  Map<int, String> subjects = {};
  Map<int, String> teachers = {};
  Map<int, String> rooms = {};

  @override
  void initState() {
    super.initState();
    weekPageController = PageController(initialPage: _weeksBack);
    appShareTimetable.addListener(_onShareSettingChanged);
    WidgetsBinding.instance.addObserver(this);
    _refreshPendingRequests();
    _pendingRequestsTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshPendingRequests(),
    );
    _restoreCachedWeeks();
    _loadSchedule();
    for (var offset = -_weeksBack; offset <= _weeksForward; offset++) {
      loadWeek(offset);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _askAboutSharingOnce());
  }

  @override
  void dispose() {
    appShareTimetable.removeListener(_onShareSettingChanged);
    weekPageController.dispose();
    _gridScroll.dispose();
    _settingsRevision.dispose();
    _pendingRequestsTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPendingRequests();
  }

  Future<void> _refreshPendingRequests() async {
    try {
      final count = await FriendService.countIncomingPending();
      if (!mounted || count == _pendingRequests) return;
      setState(() => _pendingRequests = count);
    } catch (_) {
      // Offline or a hiccup: keep showing the last known count.
    }
  }

  /// Turning sharing on uploads the weeks that are already loaded (they were
  /// skipped while sharing was off). Turning it off is handled by
  /// [_setSharing], which deletes the server copy first.
  void _onShareSettingChanged() {
    if (!appShareTimetable.value) return;

    weekLessons.forEach((offset, byDay) {
      final monday = _getMonday(DateTime.now()).add(Duration(days: 7 * offset));
      final lessons = byDay.values.expand((day) => day).toList();
      TimetableSyncService.uploadCurrentWeek(weekStart: monday, lessons: lessons);
    });
  }

  Future<void> _askAboutSharingOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_shareTimetableAskedPrefKey) == true) return;
    if (!mounted) return;

    final share = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Stundenplan mit Freunden teilen?'),
        content: const Text(
          'Wenn du teilst, wird dein Stundenplan (Fächer, Lehrer, Räume und '
          'Zeiten) auf den Timely-Servern gespeichert und ist für deine '
          'bestätigten Freunde und deine Gruppenmitglieder sichtbar.\n\n'
          'Du kannst das jederzeit unter Einstellungen > Stundenplan ändern. '
          'Beim Ausschalten werden deine geteilten Daten gelöscht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Nicht teilen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Teilen'),
          ),
        ],
      ),
    );

    await prefs.setBool(_shareTimetableAskedPrefKey, true);
    appShareTimetable.value = share == true;
  }

  Future<void> _setSharing(bool value) async {
    if (!value) {
      // Delete first; only switch off once the server copy is really gone.
      try {
        await TimetableSyncService.deleteMine();
      } catch (_) {
        if (!mounted) return;
        _showSnack('Geteilte Daten konnten nicht gelöscht werden. Bitte versuche es erneut.');
        return;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shareTimetableAskedPrefKey, true);
    appShareTimetable.value = value;
  }

  Future<void> _restoreCachedWeeks() async {
    for (var offset = -_weeksBack; offset <= _weeksForward; offset++) {
      final monday = _getMonday(DateTime.now())
          .add(Duration(days: 7 * offset));
      final cached = await _loadTimetableWeekFromCache(monday);

      if (!mounted || cached == null) continue;
      if (weekLessons.containsKey(offset)) continue;

      setState(() {
        weekLessons[offset] = _groupLessonsByDay(cached.lessons);
        weekCachedAt[offset] = cached.updatedAt;
        _syncScheduleRange();
      });
    }
  }

  /// Publishes the school's grid, widened if any loaded lesson lies outside
  /// it. Call inside setState.
  void _syncScheduleRange() {
    final lessons = weekLessons.values.expand(
      (byDay) => byDay.values.expand((day) => day),
    );
    appSchedule.value = _baseSchedule.coveringLessons(lessons);
  }

  /// Shows the cached grid of this school right away, then asks WebUntis for
  /// the current one. If that fails the cached (or fallback) grid stays.
  Future<void> _loadSchedule() async {
    final cached = await _loadScheduleFromCache(widget.school);
    if (cached != null && mounted) {
      setState(() {
        _baseSchedule = cached;
        _syncScheduleRange();
      });
    }

    try {
      final response = await webUntisRequest('getTimegridUnits', {});
      final fresh = SchoolSchedule.fromTimegrid(response['result']);
      if (fresh == null || !mounted) return;

      setState(() {
        _baseSchedule = fresh;
        _syncScheduleRange();
      });
      unawaited(_saveScheduleToCache(widget.school, fresh));
    } catch (_) {
      // Keep the cached / fallback grid.
    }
  }

  Map<DateTime, List<Lesson>> _groupLessonsByDay(List<Lesson> lessons) {
    final grouped = <DateTime, List<Lesson>>{};

    for (final lesson in lessons) {
      final day = DateTime(lesson.date.year, lesson.date.month, lesson.date.day);
      grouped.putIfAbsent(day, () => []);
      grouped[day]!.add(lesson);
    }

    for (final dayLessons in grouped.values) {
      dayLessons.sort((a, b) => a.startTime.compareTo(b.startTime));
    }

    return grouped;
  }

  /// Logs in to WebUntis again with the password saved on this device.
  /// Concurrent callers share one login.
  Future<void> _reauthenticate() {
    return _reauthFuture ??= _doReauthenticate().whenComplete(
      () => _reauthFuture = null,
    );
  }

  Future<void> _doReauthenticate() async {
    final password = await _readWebUntisPassword();
    if (password == null || password.isEmpty) {
      throw Exception('WebUntis-Sitzung abgelaufen. Bitte melde dich erneut an.');
    }

    final session = await WebUntisService.authenticate(
      school: widget.school,
      username: widget.username,
      password: password,
    );

    _sessionId = session.sessionId;
    _personId = session.personId;
    _personType = session.personType;
  }

  Future<Map<String, dynamic>> webUntisRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    // Offline cold start: we only have the cached person, no session yet.
    if (_sessionId.isEmpty) await _reauthenticate();

    Future<Map<String, dynamic>> send(String sessionId) {
      return WebUntisService.request(
        school: widget.school,
        sessionId: sessionId,
        method: method,
        params: params,
      );
    }

    final usedSession = _sessionId;
    try {
      return await send(usedSession);
    } on WebUntisSessionExpired {
      // Someone else may already have refreshed the session meanwhile.
      if (_sessionId == usedSession) await _reauthenticate();
      return send(_sessionId);
    }
  }

  /// Loads whichever of subjects/teachers/rooms is still missing. Failed
  /// lookups are retried on the next call instead of being remembered as
  /// "done" forever.
  Future<void> _ensureMasterData() {
    if (_subjectsLoaded && _teachersLoaded && _roomsLoaded) {
      return Future.value();
    }
    return _masterDataFuture ??= loadMasterData().whenComplete(
      () => _masterDataFuture = null,
    );
  }

  Future<void> loadWeek(int weekOffset) async {
    setState(() {
      weekLoading[weekOffset] = true;
      weekErrors[weekOffset] = null;
    });

    try {
      final monday = _getMonday(
        DateTime.now(),
      ).add(Duration(days: 7 * weekOffset));
      final friday = monday.add(const Duration(days: 4));
      final startDate = _formatUntisDate(monday);
      final endDate = _formatUntisDate(friday);

      final timetableResponse = await webUntisRequest('getTimetable', {
        'options': {
          'element': {'id': _personId, 'type': _personType},
          'startDate': startDate,
          'endDate': endDate,
          'onlyBaseTimetable': false,
          'showBooking': true,
          'showInfo': true,
          'showSubstText': true,
          'showLsText': true,
          'showLsNumber': true,
          'showStudentgroup': true,
        },
      });

      final timetableResult = timetableResponse['result'];

      if (timetableResult is! List) {
        throw Exception('Ungültige Stundenplan-Antwort.');
      }

      await _ensureMasterData();

      // Without subject names every lesson would read "Fach #123" - and that
      // would then be cached and uploaded to friends. Fail the load instead
      // (cached data stays visible) so a refresh can retry the lookup.
      if (!_subjectsLoaded) {
        throw Exception('Fächer konnten nicht geladen werden. Bitte versuche es erneut.');
      }

      final parsedLessons = <Lesson>[];

      for (final item in timetableResult) {
        if (item is! Map) continue;

        try {
          final lesson = Lesson.fromJson(
            Map<String, dynamic>.from(item),
            subjects: subjects,
            teachers: teachers,
            rooms: rooms,
          );
          parsedLessons.add(lesson);
        } catch (_) {
          // Ignore malformed individual lessons.
        }
      }

      final grouped = _groupLessonsByDay(parsedLessons);

      // Save the latest successful WebUntis result locally.
      unawaited(
        _saveTimetableWeekToCache(
          weekStart: monday,
          lessons: parsedLessons,
        ),
      );

      // Share this week with friends (best-effort, fire-and-forget). Every
      // week the user actually opens gets synced, so friends can scroll
      // back/forward through weeks you've already loaded.
      TimetableSyncService.uploadCurrentWeek(
        weekStart: monday,
        lessons: parsedLessons,
      );

      if (!mounted) return;

      setState(() {
        weekLessons[weekOffset] = grouped;
        weekCachedAt[weekOffset] = DateTime.now();
        weekLoading[weekOffset] = false;
        _syncScheduleRange();
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        weekLoading[weekOffset] = false;
        weekErrors[weekOffset] = _cleanError(e);
      });
    }
  }

  Future<void> loadMasterData() async {
    await Future.wait([
      if (!_subjectsLoaded) loadSubjects(),
      if (!_teachersLoaded) loadTeachers(),
      if (!_roomsLoaded) loadRooms(),
    ]);
  }

  Future<void> loadSubjects() async {
    try {
      final response = await webUntisRequest('getSubjects', {});
      final result = response['result'];

      if (result is List) {
        final map = <int, String>{};

        for (final item in result) {
          if (item is! Map) continue;
          final id = _toInt(item['id']);
          if (id == null) continue;

          final name = _firstNonEmpty([
            item['name'],
            item['longname'],
            item['displayname'],
          ]);

          if (name != null) {
            map[id] = name;
          }
        }

        subjects = map;
        _subjectsLoaded = true;
      }
    } catch (_) {
      // Stays "not loaded" so the next week load retries it.
    }
  }

  Future<void> loadTeachers() async {
    try {
      final response = await webUntisRequest('getTeachers', {});
      final result = response['result'];

      if (result is List) {
        final map = <int, String>{};

        for (final item in result) {
          if (item is! Map) continue;
          final id = _toInt(item['id']);
          if (id == null) continue;

          final name = _firstNonEmpty([
            item['name'],
            item['longname'],
            item['displayname'],
          ]);

          if (name != null) {
            map[id] = name;
          }
        }

        teachers = map;
        _teachersLoaded = true;
      }
    } catch (_) {
      // Optional, but retried on the next week load.
    }
  }

  Future<void> loadRooms() async {
    try {
      final response = await webUntisRequest('getRooms', {});
      final result = response['result'];

      if (result is List) {
        final map = <int, String>{};

        for (final item in result) {
          if (item is! Map) continue;
          final id = _toInt(item['id']);
          if (id == null) continue;

          final name = _firstNonEmpty([
            item['name'],
            item['longname'],
            item['displayname'],
          ]);

          if (name != null) {
            map[id] = name;
          }
        }

        rooms = map;
        _roomsLoaded = true;
      }
    } catch (_) {
      // Optional, but retried on the next week load.
    }
  }

  Widget buildCurrentPage() {
    switch (selectedIndex) {
      case 1:
        return FriendsPage(
          currentProfile: _profile,
          pendingRequests: _pendingRequests,
          onRequestsChanged: _refreshPendingRequests,
        );
      case 2:
        return _buildSettingsPage();
      default:
        return _buildTimetablePage();
    }
  }

  Widget _buildTimetablePage() {
    final schedule = appSchedule.value;
    final dayStartMinutes = schedule.dayStart;
    final dayEndMinutes = schedule.dayEnd;
    const timeColumnWidth = 52.0;
    // 80 px per hour keeps 08:30 -> 16:30 comfortably visible on a phone,
    // while 16:30 -> 17:15 remains available by vertical scrolling.
    const pixelsPerMinute = 80.0 / 60.0;
    final gridHeight = (dayEndMinutes - dayStartMinutes) * pixelsPerMinute;

    final isLoading = weekLoading[currentWeekOffset] ?? false;
    final currentMonday = _getMonday(
      DateTime.now(),
    ).add(Duration(days: 7 * currentWeekOffset));

    return SafeArea(
      child: Column(
        children: [
          // FIXED HEADER - stays put while swiping between weeks.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Mein Stundenplan',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (weekCachedAt[currentWeekOffset] != null) ...[
                        const SizedBox(height: 5),
                        _buildCacheStatus(currentWeekOffset),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  onPressed: isLoading ? null : () => loadWeek(currentWeekOffset),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),

          // BODY - only the day-header row + lesson columns page horizontally
          // between weeks. The hour column stays fixed on the left.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final dayColumnWidth =
                    ((constraints.maxWidth - timeColumnWidth - 5) / 5)
                        .clamp(0.0, double.infinity)
                        .toDouble();

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // FIXED LEFT COLUMN: month label above the hour markers.
                    SizedBox(
                      width: timeColumnWidth,
                      child: Column(
                        children: [
                          SizedBox(
                            height: 52,
                            child: Center(
                              child: Text(
                                _germanMonthAbbrev(currentMonday),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              controller: _gridScroll,
                              physics: const NeverScrollableScrollPhysics(),
                              child: _buildTimeLabels(
                                dayStartMinutes: dayStartMinutes,
                                dayEndMinutes: dayEndMinutes,
                                width: timeColumnWidth,
                                pixelsPerMinute: pixelsPerMinute,
                                lessonTimes: schedule.boundaries,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // PAGED CONTENT: day headers (with dates) + lesson grid.
                    Expanded(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: appShowCancelledLessons,
                        builder: (context, showCancelledLessons, _) {
                          return PageView.builder(
                            controller: weekPageController,
                            itemCount: _weekPageCount,
                            onPageChanged: (index) {
                              setState(() {
                                currentWeekOffset = index - _weeksBack;
                              });
                            },
                            itemBuilder: (context, index) {
                              final weekOffset = index - _weeksBack;
                              final loading = weekLoading[weekOffset] ?? true;
                              final error = weekErrors[weekOffset];
                              final rawLessons = weekLessons[weekOffset];
                              // "Anzeigen von Ausfällen" setting: when off, strip
                              // cancelled lessons out of each day before they
                              // ever reach the grid, so the user just sees
                              // their normal, gap-free schedule.
                              final lessons = showCancelledLessons
                                  ? rawLessons
                                  : rawLessons?.map(
                                      (day, dayLessons) => MapEntry(
                                        day,
                                        dayLessons
                                            .where((lesson) => !lesson.cancelled)
                                            .toList(),
                                      ),
                                    );

                              return RefreshIndicator(
                                onRefresh: () => loadWeek(weekOffset),
                                child: loading && lessons == null
                                    ? const Center(child: CircularProgressIndicator())
                                    : error != null && lessons == null
                                    ? _buildErrorState(weekOffset)
                                    : _buildTimetableGrid(
                                        weekOffset,
                                        lessons ?? {},
                                        dayColumnWidth: dayColumnWidth,
                                        dayStartMinutes: dayStartMinutes,
                                        dayEndMinutes: dayEndMinutes,
                                        pixelsPerMinute: pixelsPerMinute,
                                        gridHeight: gridHeight,
                                      ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimetableGrid(
    int weekOffset,
    Map<DateTime, List<Lesson>> lessons, {
    required double dayColumnWidth,
    required int dayStartMinutes,
    required int dayEndMinutes,
    required double pixelsPerMinute,
    required double gridHeight,
  }) {
    final monday = _getMonday(
      DateTime.now(),
    ).add(Duration(days: 7 * weekOffset));
    final days = List.generate(5, (index) => monday.add(Duration(days: index)));

    return Column(
      children: [
        // DAY HEADER (dates change per week, so this pages along with the
        // lesson grid below it).
        SizedBox(
          height: 52,
          child: Row(
            children: days
                .map((day) => _buildGridDayHeader(day, width: dayColumnWidth))
                .toList(),
          ),
        ),

        // ONLY THIS PART SCROLLS VERTICALLY
        Expanded(
          child: SingleChildScrollView(
            controller: _gridScroll,
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: gridHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...days.map(
                    (day) => _buildDayColumn(
                      day,
                      lessons: lessons,
                      width: dayColumnWidth,
                      height: gridHeight,
                      dayStartMinutes: dayStartMinutes,
                      pixelsPerMinute: pixelsPerMinute,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGridDayHeader(DateTime day, {required double width}) {
    final now = DateTime.now();
    final isToday =
        now.year == day.year && now.month == day.month && now.day == day.day;

    const names = ['Mo', 'Di', 'Mi', 'Do', 'Fr'];

    return Container(
      width: width,
      margin: const EdgeInsets.only(right: 1),
      decoration: BoxDecoration(
        color: isToday
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.16)
            : Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border(
          bottom: BorderSide(
            color: isToday
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
                : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            names[day.weekday - 1],
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isToday ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${day.day.toString().padLeft(2, '0')}.'
            '${day.month.toString().padLeft(2, '0')}.',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeLabels({
    required int dayStartMinutes,
    required int dayEndMinutes,
    required double width,
    required double pixelsPerMinute,
    required List<int> lessonTimes,
  }) {
    final height = (dayEndMinutes - dayStartMinutes) * pixelsPerMinute;

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          // Show every boundary of the fixed school schedule.
          for (final time in lessonTimes)
            Positioned(
              top: (time - dayStartMinutes) * pixelsPerMinute +
                  _timeLabelOffset(time, dayStartMinutes, dayEndMinutes),
              left: 0,
              right: 6,
              child: Text(
                _formatMinutes(time),
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDayColumn(
    DateTime day, {
    required Map<DateTime, List<Lesson>> lessons,
    required double width,
    required double height,
    required int dayStartMinutes,
    required double pixelsPerMinute,
  }) {
    final normalizedDay = DateTime(day.year, day.month, day.day);
    final dayLessons = _mergeConsecutiveLessons(
      lessons[normalizedDay] ?? [],
    );

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          // Subtle grid lines. These stay behind the lesson cards.
          for (final time in appSchedule.value.boundaries)
            if (time >= dayStartMinutes && time <= appSchedule.value.dayEnd)
              Positioned(
                top: (time - dayStartMinutes) * pixelsPerMinute,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 1,
                    color: Theme.of(context).colorScheme.onSurface.withValues(
                      alpha: _isLessonBoundary(time) ? 0.08 : 0.035,
                    ),
                  ),
                ),
              ),
          for (final lesson in dayLessons)
            _buildPositionedLesson(
              lesson,
              width: width,
              dayStartMinutes: dayStartMinutes,
              pixelsPerMinute: pixelsPerMinute,
            ),
        ],
      ),
    );
  }

  List<Lesson> _mergeConsecutiveLessons(List<Lesson> lessons) {
    if (lessons.length < 2) return List<Lesson>.from(lessons);

    final sorted = List<Lesson>.from(lessons)
      ..sort((a, b) {
        final aStart = a.startTime.hour * 60 + a.startTime.minute;
        final bStart = b.startTime.hour * 60 + b.startTime.minute;
        return aStart.compareTo(bStart);
      });

    final merged = <Lesson>[];

    for (final lesson in sorted) {
      if (merged.isEmpty) {
        merged.add(lesson);
        continue;
      }

      final previous = merged.last;
      final previousEnd =
          previous.endTime.hour * 60 + previous.endTime.minute;
      final lessonStart =
          lesson.startTime.hour * 60 + lesson.startTime.minute;

      // Merge same-subject lessons through the small timetable breaks, but
      // never across a real long break (15+ minutes, e.g. the lunch break).
      final crossesLongBreak = appSchedule.value.crossesLongBreak(
        previousEnd,
        lessonStart,
      );

      // A cancelled period must never merge into a normal one (or vice
      // versa) - that silently swallowed the "Entfällt" period into the
      // lesson before it, so the cancellation just disappeared from the grid.
      if (previous.subject == lesson.subject &&
          previous.cancelled == lesson.cancelled &&
          !crossesLongBreak) {
        merged[merged.length - 1] = Lesson(
          id: previous.id,
          date: previous.date,
          startTime: previous.startTime,
          endTime: lesson.endTime,
          subject: previous.subject,
          teacher: previous.teacher,
          room: previous.room,
          cancelled: previous.cancelled,
          studentGroup: previous.studentGroup,
          activityType: previous.activityType,
        );
      } else {
        merged.add(lesson);
      }
    }

    return merged;
  }

  Widget _buildPositionedLesson(
    Lesson lesson, {
    required double width,
    required int dayStartMinutes,
    required double pixelsPerMinute,
  }) {
    final start = lesson.startTime.hour * 60 + lesson.startTime.minute;
    final end = lesson.endTime.hour * 60 + lesson.endTime.minute;

    final top = (start - dayStartMinutes) * pixelsPerMinute;
    final height = (end - start) * pixelsPerMinute;

    return Positioned(
      top: top + 2,
      left: 3,
      right: 3,
      height: height - 4,
      child: _GridLessonCard(lesson: lesson),
    );
  }

  bool _isLessonBoundary(int minutes) => appSchedule.value.isLessonStart(minutes);

  // Nudges labels that would be clipped at the grid edge or overlap a
  // neighbour a few minutes away - derived from the school's time grid.
  double _timeLabelOffset(int time, int dayStartMinutes, int dayEndMinutes) {
    return appSchedule.value.labelOffset(time);
  }

  String _formatMinutes(int minutes) {
    final hour = minutes ~/ 60;
    final minute = minutes % 60;

    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  String formatShortDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.'
        '${date.month.toString().padLeft(2, '0')}.';
  }

  Widget _buildCacheStatus(int weekOffset) {
    final cachedAt = weekCachedAt[weekOffset];
    if (cachedAt == null) return const SizedBox.shrink();

    final hasError = weekErrors[weekOffset] != null;
    final label = hasError
        ? 'Offline • letzte Version ${_formatCacheTime(cachedAt)}'
        : 'Gespeichert • ${_formatCacheTime(cachedAt)}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          hasError ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
          size: 13,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ),
      ],
    );
  }

  String _formatCacheTime(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'gerade eben';
    if (difference.inMinutes < 60) return 'vor ${difference.inMinutes} Min.';
    if (difference.inHours < 24) return 'vor ${difference.inHours} Std.';
    if (difference.inDays < 7) return 'vor ${difference.inDays} Tagen';
    return '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}.${time.year}';
  }

  Widget _buildErrorState(int weekOffset) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 52,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
            ),
            const SizedBox(height: 18),
            const Text(
              'Stundenplan konnte nicht geladen werden',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              weekErrors[weekOffset] ?? 'Unbekannter Fehler',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => loadWeek(weekOffset),
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut versuchen'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDisplayName() async {
    final controller = TextEditingController(text: _profile.displayName);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name ändern'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Name'),
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

    if (newName == null || newName.isEmpty || newName == _profile.displayName) {
      return;
    }

    try {
      await ProfileService.upsertCurrentProfile(
        username: _profile.username,
        fullName: newName,
        bio: _profile.bio,
      );
      if (!mounted) return;
      setState(() {
        _profile = UserProfile(
          id: _profile.id,
          username: _profile.username,
          fullName: newName,
          bio: _profile.bio,
          schoolId: _profile.schoolId,
          webUntisSchool: _profile.webUntisSchool,
          webUntisUsername: _profile.webUntisUsername,
        );
      });
      _settingsRevision.value++;
    } catch (e) {
      if (!mounted) return;
      _showSnack(_cleanError(e));
    }
  }

  Future<void> _editUsername() async {
    final controller = TextEditingController(text: _profile.username);
    final newUsername = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Username ändern'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Username', prefixText: '@'),
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

    if (newUsername == null || newUsername.isEmpty) return;

    final normalized = _normalizeUsername(newUsername);
    if (!RegExp(r'^[a-z0-9_]{3,24}$').hasMatch(normalized)) {
      _showSnack('Benutzernamen dürfen 3-24 Zeichen haben: a-z, 0-9 und _.');
      return;
    }
    if (normalized == _profile.username) return;

    try {
      await ProfileService.upsertCurrentProfile(
        username: normalized,
        fullName: _profile.fullName,
        bio: _profile.bio,
      );
      if (!mounted) return;
      setState(() {
        _profile = _profile.copyWith(username: normalized);
      });
      _settingsRevision.value++;
    } catch (e) {
      if (!mounted) return;
      final text = e.toString().toLowerCase();
      _showSnack(
        text.contains('duplicate') || text.contains('unique')
            ? 'Dieser Username ist bereits vergeben.'
            : _cleanError(e),
      );
    }
  }

  Future<void> _editEmail() async {
    final currentEmail = supabase.auth.currentUser?.email ?? '';
    final controller = TextEditingController(text: currentEmail);
    final newEmail = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('E-Mail ändern'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Neue E-Mail-Adresse'),
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

    if (newEmail == null || newEmail.isEmpty || newEmail == currentEmail) return;
    if (!newEmail.contains('@') || !newEmail.contains('.')) {
      _showSnack('Bitte gib eine gültige E-Mail-Adresse ein.');
      return;
    }

    try {
      await supabase.auth
          .updateUser(UserAttributes(email: newEmail))
          .timeout(_supabaseTimeout);
      if (!mounted) return;
      _settingsRevision.value++;
      _showSnack(
        'Bestätigungslink an $newEmail gesendet. Die Änderung gilt erst, '
        'sobald du sie über den Link bestätigt hast.',
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack(_cleanError(e));
    }
  }

  Future<void> _editBio() async {
    final controller = TextEditingController(text: _profile.bio);
    final newBio = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bio bearbeiten'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          maxLength: 160,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Bio',
            hintText: 'Erzähl etwas über dich...',
          ),
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

    if (newBio == null || newBio == _profile.bio) {
      return;
    }

    try {
      await ProfileService.upsertCurrentProfile(
        username: _profile.username,
        fullName: _profile.fullName,
        bio: newBio,
      );
      if (!mounted) return;
      setState(() {
        _profile = _profile.copyWith(bio: newBio);
      });
      _settingsRevision.value++;
    } catch (e) {
      if (!mounted) return;
      _showSnack(_cleanError(e));
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _updatingAvatar = false;

  Future<void> _changeProfilePicture() async {
    final hasAvatar = _profile.avatarUrl != null;

    final choice = await showModalBottomSheet<_AvatarChoice>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Foto aufnehmen'),
              onTap: () => Navigator.pop(context, _AvatarChoice.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Aus Galerie wählen'),
              onTap: () => Navigator.pop(context, _AvatarChoice.gallery),
            ),
            if (hasAvatar)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Profilbild entfernen'),
                onTap: () => Navigator.pop(context, _AvatarChoice.remove),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;

    if (choice == _AvatarChoice.remove) {
      await _removeProfilePicture();
      return;
    }

    final picker = ImagePicker();
    XFile? file;
    try {
      file = await picker.pickImage(
        source: choice == _AvatarChoice.camera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 800,
        maxHeight: 800,
      );
    } catch (_) {
      if (mounted) _showSnack('Foto konnte nicht ausgewählt werden.');
      return;
    }

    if (file == null || !mounted) return;

    setState(() => _updatingAvatar = true);
    try {
      final bytes = await file.readAsBytes();
      final url = await ProfileService.uploadAvatar(bytes);

      if (!mounted) return;
      setState(() {
        _profile = _profile.copyWith(avatarUrl: url);
        _updatingAvatar = false;
      });
      unawaited(_saveProfileToCache(_profile));
      _settingsRevision.value++;
    } catch (e) {
      if (!mounted) return;
      setState(() => _updatingAvatar = false);
      _showSnack(_cleanError(e));
    }
  }

  Future<void> _removeProfilePicture() async {
    setState(() => _updatingAvatar = true);
    try {
      await ProfileService.removeAvatar();
      if (!mounted) return;
      setState(() {
        _profile = _profile.copyWith(clearAvatar: true);
        _updatingAvatar = false;
      });
      unawaited(_saveProfileToCache(_profile));
      _settingsRevision.value++;
    } catch (e) {
      if (!mounted) return;
      setState(() => _updatingAvatar = false);
      _showSnack(_cleanError(e));
    }
  }

  Future<void> _changePassword() async {
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    String? errorText;
    bool submitting = false;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Passwort ändern'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: newPasswordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Neues Passwort'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmPasswordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Passwort bestätigen'),
              ),
              if (errorText != null) ...[
                const SizedBox(height: 12),
                Text(errorText!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      final newPassword = newPasswordController.text;
                      final confirmPassword = confirmPasswordController.text;

                      if (newPassword.length < 6) {
                        setDialogState(() {
                          errorText = 'Mindestens 6 Zeichen erforderlich.';
                        });
                        return;
                      }
                      if (newPassword != confirmPassword) {
                        setDialogState(() {
                          errorText = 'Passwörter stimmen nicht überein.';
                        });
                        return;
                      }

                      setDialogState(() {
                        submitting = true;
                        errorText = null;
                      });

                      try {
                        await supabase.auth
                            .updateUser(UserAttributes(password: newPassword))
                            .timeout(_supabaseTimeout);
                        if (!context.mounted) return;
                        Navigator.pop(context);
                        _showSnack('Passwort wurde geändert.');
                      } catch (e) {
                        setDialogState(() {
                          submitting = false;
                          errorText = _cleanError(e);
                        });
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Konto löschen'),
        content: const Text(
          'Dein Timely-Konto und alle zugehörigen Daten werden endgültig gelöscht. '
          'Dieser Vorgang kann nicht rückgängig gemacht werden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Best effort: remove shared timetables before the account itself.
      try {
        await TimetableSyncService.deleteMine();
      } catch (_) {}
      await supabase.rpc('delete_account').timeout(_supabaseTimeout);
      if (!mounted) return;
      await _signOutOfTimely();
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        'Konto konnte nicht automatisch gelöscht werden. '
        'Bitte kontaktiere den Support.',
      );
    }
  }

  Future<void> _reconnectWebUntis() async {
    await _clearWebUntisPassword();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => WebUntisConnectPage(profile: _profile),
      ),
      (route) => route.isFirst,
    );
  }

  void _showInfoDialog(String title, String content) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(content)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  void _showContactDialog() {
    const contactEmail = 'kontakt.timely@gmail.com';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kontakt'),
        content: const Text('Schreib uns bei Fragen oder Feedback:\n$contactEmail'),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: contactEmail));
              Navigator.pop(context);
              _showSnack('E-Mail-Adresse kopiert.');
            },
            child: const Text('Kopieren'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsPage() {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [
          const SizedBox(height: 10),
          const Text(
            'Einstellungen',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          _SettingsCategoryCard(
            icon: Icons.person_outline,
            title: 'Profil',
            subtitle: 'Name, Profilbild, Username',
            onTap: () => _openSettingsCategory(
              icon: Icons.person_outline,
              title: 'Profil',
              tiles: _buildProfileTiles,
            ),
          ),
          const SizedBox(height: 14),
          _SettingsCategoryCard(
            icon: Icons.palette_outlined,
            title: 'Design',
            subtitle: 'Hell/Dunkel, Akzentfarbe',
            onTap: () => _openSettingsCategory(
              icon: Icons.palette_outlined,
              title: 'Design',
              tiles: _buildDesignTiles,
            ),
          ),
          const SizedBox(height: 14),
          _SettingsCategoryCard(
            icon: Icons.lock_outline,
            title: 'Konto',
            subtitle: 'Email, Passwort, Ausloggen',
            onTap: () => _openSettingsCategory(
              icon: Icons.lock_outline,
              title: 'Konto',
              tiles: _buildAccountTiles,
            ),
          ),
          const SizedBox(height: 14),
          _SettingsCategoryCard(
            icon: Icons.calendar_month_outlined,
            title: 'Stundenplan',
            subtitle: 'Schule, WebUntis Konto, Ausfälle',
            onTap: () => _openSettingsCategory(
              icon: Icons.calendar_month_outlined,
              title: 'Stundenplan',
              tiles: _buildTimetableTiles,
            ),
          ),
          const SizedBox(height: 14),
          _SettingsCategoryCard(
            icon: Icons.info_outline,
            title: 'Über Timely',
            subtitle: 'Version, Kontakt, Rechtliches',
            onTap: () => _openSettingsCategory(
              icon: Icons.info_outline,
              title: 'Über Timely',
              tiles: _buildAboutTiles,
              footer: Padding(
                padding: const EdgeInsets.only(top: 22),
                child: Center(
                  child: Text(
                    'Entwickelt von Carlos A.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openSettingsCategory({
    required IconData icon,
    required String title,
    required List<Widget> Function() tiles,
    Widget? footer,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SettingsCategoryPage(
          icon: icon,
          title: title,
          tilesBuilder: tiles,
          refresh: _settingsRevision,
          footer: footer,
        ),
      ),
    );
  }

  List<Widget> _buildProfileTiles() {
    return [
      _SettingsTile(
        icon: Icons.badge_outlined,
        title: 'Name',
        subtitle: _profile.displayName,
        onTap: _editDisplayName,
      ),
      _SettingsAvatarTile(
        initials: _initialsFor(_profile.displayName),
        avatarUrl: _profile.avatarUrl,
        loading: _updatingAvatar,
        onTap: _updatingAvatar ? null : _changeProfilePicture,
      ),
      _SettingsTile(
        icon: Icons.alternate_email,
        title: 'Username',
        subtitle: '@${_profile.username}',
        onTap: _editUsername,
      ),
      _SettingsTile(
        icon: Icons.notes_outlined,
        title: 'Bio',
        subtitle: _profile.bio.isEmpty ? 'Noch keine Bio hinzugefügt' : _profile.bio,
        onTap: _editBio,
      ),
    ];
  }

  List<Widget> _buildDesignTiles() {
    return [
      ValueListenableBuilder<ThemeMode>(
        valueListenable: appThemeMode,
        builder: (context, mode, _) => _SettingsSwitchTile(
          icon: mode == ThemeMode.light ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          title: 'Hell/Dunkel',
          subtitle: mode == ThemeMode.light ? 'Heller Modus' : 'Dunkler Modus',
          value: mode == ThemeMode.light,
          onChanged: (value) {
            appThemeMode.value = value ? ThemeMode.light : ThemeMode.dark;
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SettingsIconBadge(icon: Icons.palette_outlined),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Akzentfarbe',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<Color>(
                    valueListenable: appAccentColor,
                    builder: (context, selected, _) {
                      const colors = [
                        Color(0xFF8B5CF6),
                        Color(0xFF3B82F6),
                        Color(0xFF06B6D4),
                        Color(0xFF10B981),
                        Color(0xFFF59E0B),
                        Color(0xFFEF4444),
                        Color(0xFFEC4899),
                      ];
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final color in colors)
                            InkWell(
                              onTap: () => appAccentColor.value = color,
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: color,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: selected.toARGB32() == color.toARGB32()
                                        ? Theme.of(context).colorScheme.onSurface
                                        : Colors.transparent,
                                    width: 3,
                                  ),
                                ),
                                child: selected.toARGB32() == color.toARGB32()
                                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                                    : null,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildAccountTiles() {
    final email = supabase.auth.currentUser?.email ?? '–';
    return [
      _SettingsTile(
        icon: Icons.mail_outline,
        title: 'Email',
        subtitle: email,
        onTap: _editEmail,
      ),
      _SettingsTile(
        icon: Icons.lock_outline,
        title: 'Passwort ändern',
        onTap: _changePassword,
      ),
      _SettingsTile(
        icon: Icons.logout,
        title: 'Ausloggen',
        // _signOutOfTimely() itself pops back to the login screen, so
        // nothing extra is needed here even though this tile lives on a
        // pushed settings page.
        onTap: () => _signOutOfTimely(),
      ),
      _SettingsTile(
        icon: Icons.delete_outline,
        title: 'Konto löschen',
        destructive: true,
        onTap: _confirmDeleteAccount,
      ),
    ];
  }

  List<Widget> _buildTimetableTiles() {
    return [
      _SettingsTile(
        icon: Icons.school_outlined,
        title: 'Schule',
        subtitle: widget.school,
      ),
      _SettingsTile(
        icon: Icons.link,
        title: 'WebUntis Konto',
        subtitle: widget.username,
        onTap: _reconnectWebUntis,
      ),
      ValueListenableBuilder<bool>(
        valueListenable: appShowCancelledLessons,
        builder: (context, showCancelled, _) => _SettingsSwitchTile(
          icon: Icons.event_busy_outlined,
          title: 'Anzeigen von Ausfällen',
          subtitle: showCancelled ? 'Ausfälle werden angezeigt' : 'Ausfälle sind ausgeblendet',
          value: showCancelled,
          onChanged: (value) => appShowCancelledLessons.value = value,
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: appShareTimetable,
        builder: (context, sharing, _) => _SettingsSwitchTile(
          icon: Icons.group_outlined,
          title: 'Stundenplan teilen',
          subtitle: sharing
              ? 'Sichtbar für Freunde und Gruppenmitglieder'
              : 'Nicht geteilt - Freunde sehen nichts',
          value: sharing,
          onChanged: _setSharing,
        ),
      ),
    ];
  }

  List<Widget> _buildAboutTiles() {
    return [
      const _SettingsTile(
        icon: Icons.info_outline,
        title: 'Version',
        subtitle: '1.0.0',
      ),
      _SettingsTile(
        icon: Icons.apps_outlined,
        title: 'Über',
        onTap: () => _showInfoDialog(
          'Über Timely',
          'Timely ist dein persönlicher WebUntis-Stundenplan-Client – '
              'übersichtlich, schnell und mit Freunden teilbar.',
        ),
      ),
      _SettingsTile(
        icon: Icons.slideshow_outlined,
        title: 'Einführung erneut ansehen',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const IntroPage(isReplay: true)),
          );
        },
      ),
      _SettingsTile(
        icon: Icons.privacy_tip_outlined,
        title: 'Privatsphäre',
        onTap: () => _showInfoDialog('Privatsphäre', kPrivacyText()),
      ),
      _SettingsTile(
        icon: Icons.description_outlined,
        title: 'Regeln',
        onTap: () => _showInfoDialog('Nutzungsbedingungen', kTermsText()),
      ),
      _SettingsTile(
        icon: Icons.support_agent_outlined,
        title: 'Kontakt',
        onTap: _showContactDialog,
      ),
      _SettingsTile(
        icon: Icons.flag_outlined,
        title: 'Problem melden',
        onTap: () => _showInfoDialog(
          'Problem melden',
          'Bitte beschreibe dein Problem und schick es an '
              'kontakt.timely@gmail.com – wir kümmern uns schnellstmöglich darum.',
        ),
      ),
    ];
  }

  String _initialsFor(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: buildCurrentPage(),
      bottomNavigationBar: _SlidingNavBar(
        selectedIndex: selectedIndex,
        onSelected: (index) {
          setState(() => selectedIndex = index);
          _refreshPendingRequests();
        },
        items: [
          const _NavItem(
            icon: Icons.calendar_month_outlined,
            selectedIcon: Icons.calendar_month,
            label: 'Stundenplan',
          ),
          _NavItem(
            icon: Icons.people_outline,
            selectedIcon: Icons.people,
            label: 'Freunde',
            badgeCount: _pendingRequests,
          ),
          const _NavItem(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: 'Einstellungen',
          ),
        ],
      ),
    );
  }
}

/// Text for a notification badge: the number, capped at "9+".

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Shows a small badge on the icon when greater than zero.
  final int badgeCount;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount = 0,
  });
}

/// Bottom bar like Material's NavigationBar, except the oval highlight
/// glides from the old tab to the new one instead of fading out and in.

class _SlidingNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<_NavItem> items;

  const _SlidingNavBar({
    required this.selectedIndex,
    required this.onSelected,
    required this.items,
  });

  static const double _height = 80;
  static const double _pillWidth = 64;
  static const double _pillHeight = 32;
  static const double _labelHeight = 16;
  static const double _gap = 4;
  static const Duration _duration = Duration(milliseconds: 320);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = constraints.maxWidth / items.length;
              const contentHeight = _pillHeight + _gap + _labelHeight;
              const pillTop = (_height - contentHeight) / 2;

              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: _duration,
                    curve: Curves.easeOutCubic,
                    left: selectedIndex * itemWidth + (itemWidth - _pillWidth) / 2,
                    top: pillTop,
                    width: _pillWidth,
                    height: _pillHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(_pillHeight / 2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Expanded(child: _buildItem(scheme, i)),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildItem(ColorScheme scheme, int index) {
    final item = items[index];
    final selected = index == selectedIndex;

    return Semantics(
      button: true,
      selected: selected,
      label: item.badgeCount > 0
          ? '${item.label}, ${item.badgeCount} neu'
          : item.label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelected(index),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: selected ? 1.0 : 0.0),
            duration: _duration,
            curve: Curves.easeOutCubic,
            builder: (context, t, _) {
              final iconColor = Color.lerp(
                scheme.onSurfaceVariant,
                scheme.onSecondaryContainer,
                t,
              )!;
              final labelColor = Color.lerp(
                scheme.onSurfaceVariant,
                scheme.onSurface,
                t,
              )!;

              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: _pillHeight,
                    child: Center(
                      child: Badge(
                        isLabelVisible: item.badgeCount > 0,
                        label: Text(_badgeText(item.badgeCount)),
                        child: Icon(
                          t >= 0.5 ? item.selectedIcon : item.icon,
                          size: 24,
                          color: iconColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: _gap),
                  SizedBox(
                    height: _labelHeight,
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.33,
                        fontWeight: t >= 0.5 ? FontWeight.w600 : FontWeight.w500,
                        color: labelColor,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
part of '../main.dart';

class FriendTimetablePage extends StatefulWidget {
  final UserProfile friend;

  const FriendTimetablePage({super.key, required this.friend});

  @override
  State<FriendTimetablePage> createState() => _FriendTimetablePageState();
}

class _FriendTimetablePageState extends State<FriendTimetablePage> {
  static const int _weeksBack = 2;
  static const int _weeksForward = 2;
  static const int _weekPageCount = _weeksBack + _weeksForward + 1;

  late final PageController _weekPageController;
  final _LinkedScrollController _gridScroll = _LinkedScrollController();
  int currentWeekOffset = 0;
  bool comparing = false;

  // Set just before a week's columns are built (see _buildWeekGrid) to
  // whether comparison highlighting is trustworthy for that specific week.
  bool _activeCompare = false;

  // Per-week-offset state, mirroring how the user's own timetable page
  // caches loaded weeks. Offset 0 is the current week.
  final Map<int, Map<DateTime, List<Lesson>>> friendWeekLessons = {};
  final Map<int, Map<DateTime, List<Lesson>>> myWeekLessons = {};
  final Map<int, bool> weekLoading = {};
  final Map<int, String?> weekErrors = {};

  // Weeks for which there is no synced row at all (as opposed to a
  // genuinely empty week, e.g. a holiday). Comparing must not treat these
  // as "free" - that's exactly what showed everything as mutual free time
  // whenever the current user's own sharing was off or hadn't synced yet.
  final Set<int> myNoDataWeeks = {};
  final Set<int> friendNoDataWeeks = {};

  /// Whether "gemeinsam frei" / shared-lesson highlighting can be trusted
  /// for [weekOffset] - false whenever either side's timetable was never
  /// actually synced for that week.
  bool _canCompare(int weekOffset) {
    return !myNoDataWeeks.contains(weekOffset) &&
        !friendNoDataWeeks.contains(weekOffset);
  }

  @override
  void initState() {
    super.initState();
    _weekPageController = PageController(initialPage: _weeksBack);
    for (var offset = -_weeksBack; offset <= _weeksForward; offset++) {
      _loadWeek(offset);
    }
  }

  @override
  void dispose() {
    _weekPageController.dispose();
    _gridScroll.dispose();
    super.dispose();
  }

  Future<void> _loadWeek(int weekOffset) async {
    setState(() {
      weekLoading[weekOffset] = true;
      weekErrors[weekOffset] = null;
    });

    try {
      final monday = _getMonday(
        DateTime.now(),
      ).add(Duration(days: 7 * weekOffset));
      final myUserId = supabase.auth.currentUser?.id;

      final friendLessons = await TimetableSyncService.loadWeek(
        userId: widget.friend.id,
        weekStart: monday,
      );
      final myLessons = myUserId == null
          ? null
          : await TimetableSyncService.loadWeek(
              userId: myUserId,
              weekStart: monday,
            );

      if (!mounted) return;

      setState(() {
        friendWeekLessons[weekOffset] = _groupByDay(friendLessons ?? []);
        myWeekLessons[weekOffset] = _groupByDay(myLessons ?? []);

        if (friendLessons == null) {
          friendNoDataWeeks.add(weekOffset);
        } else {
          friendNoDataWeeks.remove(weekOffset);
        }

        if (myLessons == null) {
          myNoDataWeeks.add(weekOffset);
        } else {
          myNoDataWeeks.remove(weekOffset);
        }

        weekLoading[weekOffset] = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        weekErrors[weekOffset] = _cleanError(e);
        weekLoading[weekOffset] = false;
      });
    }
  }

  Map<DateTime, List<Lesson>> _groupByDay(List<Lesson> lessons) {
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

  /// Whether [lesson] (one of the friend's active lessons) matches one of
  /// my own active lessons at the same day/time - i.e. we share the class.
  bool _isShared(Lesson lesson, Map<DateTime, List<Lesson>> myLessonsByDay) {
    if (!_activeCompare || lesson.cancelled) return false;

    for (final dayLessons in myLessonsByDay.values) {
      for (final mine in dayLessons) {
        if (!mine.cancelled && mine.matchesForComparison(lesson)) return true;
      }
    }

    return false;
  }

  /// Whether a cancelled lesson of the friend's leaves both of us free during
  /// its time slot - i.e. I don't have an active lesson of my own then either.
  bool _isCancelledAndMutuallyFree(
    Lesson lesson,
    Map<DateTime, List<Lesson>> myLessonsByDay,
  ) {
    if (!_activeCompare || !lesson.cancelled) return false;

    final day = DateTime(lesson.date.year, lesson.date.month, lesson.date.day);
    final start = lesson.startTime.hour * 60 + lesson.startTime.minute;
    final end = lesson.endTime.hour * 60 + lesson.endTime.minute;

    for (final mine in myLessonsByDay[day] ?? const <Lesson>[]) {
      if (mine.cancelled) continue;
      final mineStart = mine.startTime.hour * 60 + mine.startTime.minute;
      final mineEnd = mine.endTime.hour * 60 + mine.endTime.minute;
      if (mineStart < end && mineEnd > start) return false;
    }

    return true;
  }

  /// Whether both the friend and I have nothing on (no lesson, or only
  /// cancelled ones) during [periodStart]-[periodEnd] on [day].
  bool _isMutualFreeSlot(
    DateTime day,
    int periodStart,
    int periodEnd,
    Map<DateTime, List<Lesson>> friendLessonsByDay,
    Map<DateTime, List<Lesson>> myLessonsByDay,
  ) {
    if (!_activeCompare) return false;

    bool occupied(Map<DateTime, List<Lesson>> byDay) {
      for (final lesson in byDay[day] ?? const <Lesson>[]) {
        if (lesson.cancelled) continue;
        final start = lesson.startTime.hour * 60 + lesson.startTime.minute;
        final end = lesson.endTime.hour * 60 + lesson.endTime.minute;
        if (start < periodEnd && end > periodStart) return true;
      }
      return false;
    }

    return !occupied(friendLessonsByDay) && !occupied(myLessonsByDay);
  }

  /// Groups consecutive free lesson periods into one continuous green block.
  /// Small timetable breaks between periods are included visually, while an
  /// occupied lesson still splits the blocks.
  List<List<int>> _mutualFreeRanges(
    DateTime day,
    Map<DateTime, List<Lesson>> friendLessonsByDay,
    Map<DateTime, List<Lesson>> myLessonsByDay,
  ) {
    final ranges = <List<int>>[];
    int? rangeStart;
    int? rangeEnd;

    for (final period in _lessonPeriods) {
      final isFree = _isMutualFreeSlot(
        day,
        period[0],
        period[1],
        friendLessonsByDay,
        myLessonsByDay,
      );

      if (isFree) {
        rangeStart ??= period[0];
        rangeEnd = period[1];
      } else if (rangeStart != null) {
        ranges.add([rangeStart, rangeEnd!]);
        rangeStart = null;
        rangeEnd = null;
      }
    }

    if (rangeStart != null) {
      ranges.add([rangeStart, rangeEnd!]);
    }

    return ranges;
  }

  @override
  Widget build(BuildContext context) {
    final schedule = appSchedule.value;
    final dayStartMinutes = schedule.dayStart;
    final dayEndMinutes = schedule.dayEnd;
    const timeColumnWidth = 52.0;
    const pixelsPerMinute = 80.0 / 60.0;
    final gridHeight = (dayEndMinutes - dayStartMinutes) * pixelsPerMinute;

    final isLoading = weekLoading[currentWeekOffset] ?? false;
    final currentMonday = _getMonday(
      DateTime.now(),
    ).add(Duration(days: 7 * currentWeekOffset));

    return Scaffold(
      appBar: AppBar(
        title: Text('${_possessiveName(widget.friend.displayName)} Stundenplan'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // FIXED CONTROLS - stay put while swiping between weeks.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
              child: Row(
                children: [
                  const Spacer(),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: comparing ? Colors.green : null,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    onPressed: () => setState(() => comparing = !comparing),
                    icon: Icon(comparing ? Icons.check : Icons.compare_arrows, size: 18),
                    label: const Text('Vergleiche'),
                  ),
                  IconButton(
                    onPressed: isLoading ? null : () => _loadWeek(currentWeekOffset),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),

            // BODY - only the day-header row + lesson columns page
            // horizontally between weeks. The hour column stays fixed.
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

                      // PAGED CONTENT
                      Expanded(
                        child: PageView.builder(
                          controller: _weekPageController,
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
                            final friendLessons = friendWeekLessons[weekOffset];
                            final myLessons = myWeekLessons[weekOffset] ?? {};

                            return RefreshIndicator(
                              onRefresh: () => _loadWeek(weekOffset),
                              child: loading && friendLessons == null
                                  ? const Center(child: CircularProgressIndicator())
                                  : error != null && friendLessons == null
                                  ? _buildErrorState(weekOffset, error)
                                  : _buildWeekGrid(
                                      weekOffset,
                                      friendLessons ?? {},
                                      myLessons,
                                      dayColumnWidth: dayColumnWidth,
                                      dayStartMinutes: dayStartMinutes,
                                      dayEndMinutes: dayEndMinutes,
                                      pixelsPerMinute: pixelsPerMinute,
                                      gridHeight: gridHeight,
                                    ),
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
      ),
    );
  }

  Widget _buildErrorState(int weekOffset, String error) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _MessageBox(icon: Icons.error_outline, color: Colors.redAccent, message: error),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _loadWeek(weekOffset),
          icon: const Icon(Icons.refresh),
          label: const Text('Erneut versuchen'),
        ),
      ],
    );
  }

  Widget _buildWeekGrid(
    int weekOffset,
    Map<DateTime, List<Lesson>> friendLessonsByDay,
    Map<DateTime, List<Lesson>> myLessonsByDay, {
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

    final isEmpty = friendLessonsByDay.isEmpty;

    if (isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _EmptyLine(
            text: weekOffset == 0
                ? 'Noch kein geteilter Stundenplan vorhanden.'
                : 'Für diese Woche liegt noch kein geteilter Stundenplan vor.',
          ),
        ),
      );
    }

    // Read by _isShared/_isCancelledAndMutuallyFree/_mutualFreeRanges while
    // this week's columns are being built below, so the green "gemeinsam
    // frei" highlighting never shows for a week where one side's data was
    // never actually synced (that data being missing must not be read as
    // "this person is free").
    final canCompareThisWeek = comparing && _canCompare(weekOffset);
    _activeCompare = canCompareThisWeek;

    return Column(
      children: [
        if (comparing && !canCompareThisWeek)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _MessageBox(
              icon: Icons.info_outline,
              color: Colors.amber,
              message: myNoDataWeeks.contains(weekOffset)
                  ? 'Vergleichen geht für diese Woche nicht: Dein eigener Stundenplan '
                        'ist für diese Woche nicht geteilt. Aktiviere "Stundenplan teilen" '
                        'in den Einstellungen oder öffne diese Woche einmal in deinem eigenen Stundenplan.'
                  : 'Vergleichen geht für diese Woche nicht: '
                        '${widget.friend.displayName} hat für diese Woche noch nichts geteilt.',
            ),
          ),
        SizedBox(
          height: 52,
          child: Row(
            children: days
                .map((day) => _buildGridDayHeader(day, width: dayColumnWidth))
                .toList(),
          ),
        ),
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
                      friendLessonsByDay: friendLessonsByDay,
                      myLessonsByDay: myLessonsByDay,
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
    required Map<DateTime, List<Lesson>> friendLessonsByDay,
    required Map<DateTime, List<Lesson>> myLessonsByDay,
    required double width,
    required double height,
    required int dayStartMinutes,
    required double pixelsPerMinute,
  }) {
    final normalizedDay = DateTime(day.year, day.month, day.day);
    final dayLessons = _mergeConsecutiveLessons(
      friendLessonsByDay[normalizedDay] ?? [],
    );

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          // Subtle grid lines. These stay behind everything else.
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
          // When comparing, show one continuous green block for consecutive
          // periods where we are both free. Timetable breaks between those
          // periods are included visually, but an actual lesson splits blocks.
          if (comparing)
            for (final range in _mutualFreeRanges(
              normalizedDay,
              friendLessonsByDay,
              myLessonsByDay,
            ))
              Positioned(
                top: (range[0] - dayStartMinutes) * pixelsPerMinute + 2,
                left: 3,
                right: 3,
                height: (range[1] - range[0]) * pixelsPerMinute - 4,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: Colors.green.withValues(alpha: 0.35),
                      ),
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
              highlighted: _isShared(lesson, myLessonsByDay) ||
                  _isCancelledAndMutuallyFree(lesson, myLessonsByDay),
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
    bool highlighted = false,
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
      child: _GridLessonCard(lesson: lesson, highlighted: highlighted),
    );
  }

  // (start, end) pairs for each actual lesson period, used to figure out
  // "both free" slots for the comparison highlighting.
  List<List<int>> get _lessonPeriods => appSchedule.value.periods;

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
}

/// WebUntis says the session is gone (expired / logged out elsewhere).
/// [_HomePageState] reacts by logging in again with the saved password.
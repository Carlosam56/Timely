part of '../main.dart';

class GroupTimetablePage extends StatefulWidget {
  final FriendGroup group;
  final UserProfile myProfile;

  const GroupTimetablePage({super.key, required this.group, required this.myProfile});

  @override
  State<GroupTimetablePage> createState() => _GroupTimetablePageState();
}

class _GroupTimetablePageState extends State<GroupTimetablePage> {
  late FriendGroup group;
  late String selectedMemberId;
  bool comparing = false;
  int weekOffset = 0;
  bool loading = true;
  String? errorMessage;
  bool leavingOrDeleting = false;

  // weekOffset -> memberId -> day -> lessons
  final Map<int, Map<String, Map<DateTime, List<Lesson>>>> weekLessons = {};

  List<List<int>> get _lessonPeriods => appSchedule.value.periods;

  int get _dayStartMinutes => appSchedule.value.dayStart;
  int get _dayEndMinutes => appSchedule.value.dayEnd;

  @override
  void initState() {
    super.initState();
    group = widget.group;
    selectedMemberId = widget.myProfile.id;
    _loadWeek(weekOffset);
  }

  Future<void> _loadWeek(int offset) async {
    setState(() {
      loading = true;
      errorMessage = null;
    });

    try {
      final monday = _getMonday(DateTime.now()).add(Duration(days: 7 * offset));

      final results = await Future.wait(
        group.members.map((member) async {
          final lessons = await TimetableSyncService.loadWeek(
            userId: member.id,
            weekStart: monday,
          );
          return MapEntry(member.id, _groupByDay(lessons ?? []));
        }),
      );

      if (!mounted) return;

      setState(() {
        weekLessons[offset] = {for (final entry in results) entry.key: entry.value};
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

  Map<DateTime, List<Lesson>> _groupByDay(List<Lesson> lessons) {
    final grouped = <DateTime, List<Lesson>>{};
    for (final lesson in lessons) {
      final day = DateTime(lesson.date.year, lesson.date.month, lesson.date.day);
      grouped.putIfAbsent(day, () => []);
      grouped[day]!.add(lesson);
    }
    return grouped;
  }

  void _changeWeek(int delta) {
    final newOffset = weekOffset + delta;
    setState(() => weekOffset = newOffset);
    if (weekLessons[newOffset] == null) {
      _loadWeek(newOffset);
    }
  }

  /// Null if [memberId] is free during [start]-[end] on [day], otherwise the
  /// (lowercased) subject signature of what they have then.
  String? _signature(String memberId, DateTime day, int start, int end) {
    final byDay = weekLessons[weekOffset]?[memberId] ?? {};
    for (final lesson in byDay[day] ?? const <Lesson>[]) {
      if (lesson.cancelled) continue;
      final s = lesson.startTime.hour * 60 + lesson.startTime.minute;
      final e = lesson.endTime.hour * 60 + lesson.endTime.minute;
      if (s < end && e > start) return lesson.subject.trim().toLowerCase();
    }
    return null;
  }

  String _labelFor(String? signature, String sampleMemberId, DateTime day, int start, int end) {
    if (signature == null) return 'Frei';
    final byDay = weekLessons[weekOffset]?[sampleMemberId] ?? {};
    for (final lesson in byDay[day] ?? const <Lesson>[]) {
      if (lesson.cancelled) continue;
      if (lesson.subject.trim().toLowerCase() == signature) return lesson.subject;
    }
    return signature;
  }

  /// For [day]/[start]-[end], finds every group member (including
  /// [selectedMemberId]) whose signature matches the selected member's - i.e.
  /// who shares whatever the selected member is doing then (free, or a
  /// specific subject).
  List<String> _sharingMembers(DateTime day, int start, int end) {
    final targetSig = _signature(selectedMemberId, day, start, end) ?? '__free__';
    final sharing = <String>[];
    for (final member in group.members) {
      final sig = _signature(member.id, day, start, end) ?? '__free__';
      if (sig == targetSig) sharing.add(member.id);
    }
    return sharing;
  }

  UserProfile _profileFor(String id) {
    return group.members.firstWhere(
      (m) => m.id == id,
      orElse: () => UserProfile(id: id, username: '?', fullName: '?'),
    );
  }

  void _showSharingSheet(DateTime day, int start, int end, List<String> sharing) {
    final sig = _signature(selectedMemberId, day, start, end);
    final label = _labelFor(sig, selectedMemberId, day, start, end);
    final allMembers = group.members.map((m) => m.id).toList();

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sig == null ? 'Gemeinsam frei' : label,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '${_formatMinutesStatic(start)} - ${_formatMinutesStatic(end)}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 14),
              ...allMembers.map((id) {
                final profile = _profileFor(id);
                final shares = sharing.contains(id);
                final memberSig = _signature(id, day, start, end);
                final personLabel = memberSig == null ? 'Frei' : _labelFor(memberSig, id, day, start, end);

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        shares ? Icons.check_circle : Icons.circle_outlined,
                        color: shares
                            ? Colors.green
                            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(profile.displayName)),
                      Text(
                        personLabel,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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
    );
  }

  static String _formatMinutesStatic(int minutes) {
    final hour = minutes ~/ 60;
    final minute = minutes % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final monday = _getMonday(DateTime.now()).add(Duration(days: 7 * weekOffset));
    final days = List.generate(5, (i) => monday.add(Duration(days: i)));
    final byMember = weekLessons[weekOffset];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor: Color(group.avatarColor).withValues(alpha: 0.22),
              backgroundImage:
                  group.avatarUrl != null ? NetworkImage(group.avatarUrl!) : null,
              child: group.avatarUrl == null
                  ? Text(group.avatarEmoji, style: const TextStyle(fontSize: 13))
                  : null,
            ),
            const SizedBox(width: 10),
            Flexible(child: Text(group.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: selectedMemberId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(),
                      ),
                      items: group.members.map((member) {
                        final isMe = member.id == widget.myProfile.id;
                        return DropdownMenuItem(
                          value: member.id,
                          child: Text(
                            isMe ? '${member.displayName} (Ich)' : member.displayName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => selectedMemberId = value);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: comparing ? Colors.green : null,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    ),
                    onPressed: () => setState(() => comparing = !comparing),
                    icon: Icon(comparing ? Icons.check : Icons.compare_arrows, size: 18),
                    label: const Text('Vergleichen'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => _changeWeek(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '${_germanMonthAbbrev(monday)} ${monday.day}. - ${days.last.day}.',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _changeWeek(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
            if (errorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _MessageBox(icon: Icons.error_outline, color: Colors.redAccent, message: errorMessage!),
              ),
            if (!comparing)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: _EmptyLine(text: 'Tippe auf "Vergleichen", um Gemeinsamkeiten mit der Gruppe zu sehen.'),
              ),
            Expanded(
              child: loading && byMember == null
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        const timeColumnWidth = 44.0;
                        const pixelsPerMinute = 80.0 / 60.0;
                        final dayColumnWidth =
                            ((constraints.maxWidth - timeColumnWidth - 5) / 5)
                                .clamp(0.0, double.infinity)
                                .toDouble();
                        final gridHeight = (_dayEndMinutes - _dayStartMinutes) * pixelsPerMinute;

                        return SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: 42,
                                child: Row(
                                  children: [
                                    SizedBox(width: timeColumnWidth),
                                    ...days.map((day) => _buildDayHeader(day, width: dayColumnWidth)),
                                  ],
                                ),
                              ),
                              SizedBox(
                                height: gridHeight,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: timeColumnWidth,
                                      height: gridHeight,
                                      child: Stack(
                                        children: [
                                          for (final period in _lessonPeriods)
                                            Positioned(
                                              top: (period[0] - _dayStartMinutes) * pixelsPerMinute,
                                              left: 0,
                                              right: 4,
                                              child: Text(
                                                _formatMinutesStatic(period[0]),
                                                textAlign: TextAlign.right,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    ...days.map(
                                      (day) => _buildDayColumn(
                                        day,
                                        width: dayColumnWidth,
                                        height: gridHeight,
                                        pixelsPerMinute: pixelsPerMinute,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDayHeader(DateTime day, {required double width}) {
    const names = ['Mo', 'Di', 'Mi', 'Do', 'Fr'];
    return Container(
      width: width,
      alignment: Alignment.center,
      child: Text(
        '${names[day.weekday - 1]} ${day.day}.${day.month}.',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildDayColumn(
    DateTime day, {
    required double width,
    required double height,
    required double pixelsPerMinute,
  }) {
    final normalizedDay = DateTime(day.year, day.month, day.day);
    final blocks = <Widget>[];
    final totalMembers = group.members.length;

    // Merge consecutive periods that share the same signature (free, or the
    // same subject) for the selected member into one continuous block.
    String? currentSig;
    int? rangeStart;
    int? rangeEnd;

    void flush() {
      if (rangeStart == null) return;
      // Capture as locals so each block's closures freeze this block's own
      // range - otherwise every onTap would share the same mutable
      // rangeStart/rangeEnd and all fire with whatever the LAST block in
      // this day column ended up being.
      final blockStart = rangeStart;
      final blockEnd = rangeEnd!;
      final sig = currentSig;
      final sharing = comparing
          ? _sharingMembers(normalizedDay, blockStart, blockEnd)
          : <String>[selectedMemberId];
      final isAll = comparing && sharing.length == totalMembers;
      final isSome = comparing && sharing.length >= 2 && !isAll;
      final color = isAll ? Colors.green : (isSome ? Colors.amber : null);
      final label = _labelFor(sig, selectedMemberId, normalizedDay, blockStart, blockEnd);
      final surface = Theme.of(context).colorScheme.surface;
      final onSurface = Theme.of(context).colorScheme.onSurface;
      // Blend to an opaque color instead of a translucent one, so the hour
      // gridlines don't show through the block.
      final fillColor = Color.alphaBlend(
        (color ?? onSurface).withValues(alpha: color == null ? 0.10 : 0.30),
        surface,
      );

      blocks.add(
        Positioned(
          top: (blockStart - _dayStartMinutes) * pixelsPerMinute + 2,
          left: 3,
          right: 3,
          height: (blockEnd - blockStart) * pixelsPerMinute - 4,
          child: GestureDetector(
            onTap: color == null
                ? null
                : () => _showSharingSheet(normalizedDay, blockStart, blockEnd, sharing),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: fillColor,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: color ?? onSurface.withValues(alpha: 0.18),
                  width: 1.4,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sig == null ? 'Frei' : label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                  if (comparing)
                    Text(
                      '${sharing.length}/$totalMembers',
                      style: TextStyle(
                        fontSize: 10,
                        color: onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    for (final period in _lessonPeriods) {
      final sig = _signature(selectedMemberId, normalizedDay, period[0], period[1]);

      if (sig == currentSig && rangeStart != null) {
        rangeEnd = period[1];
      } else {
        flush();
        currentSig = sig;
        rangeStart = period[0];
        rangeEnd = period[1];
      }
    }
    flush();

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          for (final time in _lessonPeriods.map((p) => p[0]))
            Positioned(
              top: (time - _dayStartMinutes) * pixelsPerMinute,
              left: 0,
              right: 0,
              child: Container(
                height: 1,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
              ),
            ),
          ...blocks,
        ],
      ),
    );
  }
}

/// The "add friends" screen: search for people plus incoming/outgoing
/// requests. Reached via the icon in the corner of [FriendsPage].
part of '../main.dart';

String _badgeText(int count) => count > 9 ? '9+' : '$count';

String _formatIsoDate(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

int? _untisTimeToMinutes(dynamic value) {
  final t = _toInt(value);
  if (t == null) return null;
  return (t ~/ 100) * 60 + t % 100;
}

/// A school's time grid: the lesson periods of a day as (start, end) minutes
/// since midnight. Everything the timetable grids used to hardcode - hour
/// lines, labels, where the day starts and ends, which breaks are "long" -
/// is derived from these periods.

int? _toInt(dynamic value) {
  if (value is int) return value;

  if (value is double) {
    return value.toInt();
  }

  if (value is String) {
    return int.tryParse(value);
  }

  return null;
}

int? _extractFirstId(dynamic value) {
  if (value is List && value.isNotEmpty) {
    final first = value.first;

    if (first is Map) {
      return _toInt(first['id']);
    }
  }

  return null;
}

String? _firstNonEmpty(List<dynamic> values) {
  for (final value in values) {
    if (value == null) continue;

    final text = value.toString().trim();

    if (text.isNotEmpty) {
      return text;
    }
  }

  return null;
}

DateTime _parseUntisDate(dynamic value) {
  final text = value.toString();

  if (text.length != 8) {
    throw Exception('Ungültiges Datum: $value');
  }

  final year = int.parse(text.substring(0, 4));
  final month = int.parse(text.substring(4, 6));
  final day = int.parse(text.substring(6, 8));

  return DateTime(year, month, day);
}

TimeOfDay _parseUntisTime(dynamic value) {
  final time = _toInt(value) ?? 0;

  final hour = time ~/ 100;
  final minute = time % 100;

  return TimeOfDay(hour: hour, minute: minute);
}

String _formatUntisDate(DateTime date) {
  return '${date.year}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';
}

DateTime _getMonday(DateTime date) {
  return DateTime(
    date.year,
    date.month,
    date.day,
  ).subtract(Duration(days: date.weekday - 1));
}

/// German 3-letter month abbreviation (Jan, Feb, Mär, ...), shown in the
/// corner above the hour markers of a timetable grid.

String _germanMonthAbbrev(DateTime date) {
  const names = [
    'Jan',
    'Feb',
    'Mär',
    'Apr',
    'Mai',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Okt',
    'Nov',
    'Dez',
  ];

  return names[date.month - 1];
}

String weekdayName(int weekday) {
  const names = [
    'Montag',
    'Dienstag',
    'Mittwoch',
    'Donnerstag',
    'Freitag',
    'Samstag',
    'Sonntag',
  ];

  return names[weekday - 1];
}

/// German possessive form of a name for page titles ("Leylas Stundenplan",
/// "Lukas' Stundenplan").

String _possessiveName(String name) {
  if (name.isEmpty) return name;

  final lower = name.toLowerCase();
  if (lower.endsWith('s') || lower.endsWith('x') || lower.endsWith('z')) {
    return "$name'";
  }

  return '${name}s';
}

String _cleanError(Object error) {
  if (error is TimeoutException) {
    return 'Zeitüberschreitung. Bitte überprüfe deine Internetverbindung.';
  }

  final message = error.toString();

  if (message.startsWith('Exception: ')) {
    return message.substring(11);
  }

  if (message.startsWith('AuthException(')) {
    return message
        .replaceFirst('AuthException(message: ', '')
        .replaceFirst(RegExp(r', statusCode:.*\)$'), '');
  }

  if (message.startsWith('PostgrestException(')) {
    final match = RegExp(r'message: ([^,]+)').firstMatch(message);
    return match?.group(1) ?? message;
  }

  return message;
}

String _normalizeUsername(String value) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_]'), '_');

  if (normalized.length > 24) {
    return normalized.substring(0, 24);
  }

  return normalized;
}
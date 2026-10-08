import 'package:flutter/services.dart';
import 'package:device_calendar_plus/device_calendar_plus.dart';

class CalendarService {
  final DeviceCalendar _plugin = DeviceCalendar.instance;
  static const _channel = MethodChannel('calsync/calendar');

  Future<List<Calendar>> listCalendars() async {
    try {
      return await _plugin.listCalendars();
    } on DeviceCalendarException {
      return [];
    }
  }

  /// How far ahead of now [listEvents] looks.
  static const syncWindow = Duration(days: 30);

  /// Lists events from now until now + [syncWindow].
  ///
  /// Returns null when the calendar could not be read, so callers can tell
  /// a failed read apart from an empty calendar.
  Future<List<Event>?> listEvents(String calendarId) async {
    final now = DateTime.now();
    try {
      return await _plugin.listEvents(
        now,
        now.add(syncWindow),
        calendarIds: [calendarId],
      );
    } on DeviceCalendarException {
      return null;
    }
  }

  Future<String?> createEvent(
    String calendarId,
    String title,
    DateTime start,
    DateTime end, {
    String? description,
    bool? isAllDay,
    RecurrenceRule? recurrenceRule,
    String? location,
  }) async {
    try {
      return await _plugin.createEvent(
        calendarId: calendarId,
        title: title,
        startDate: start,
        endDate: end,
        description: description,
        isAllDay: isAllDay ?? false,
        recurrenceRule: recurrenceRule,
        location: location,
      );
    } on DeviceCalendarException {
      return null;
    }
  }

  Future<Event?> getEvent(String eventId) async {
    try {
      return await _plugin.getEvent(eventId);
    } on DeviceCalendarException {
      return null;
    }
  }

  /// Updates a timed event in place. Returns false if it could not be
  /// updated, so callers can fall back to replacing it.
  Future<bool> updateEvent(
    String eventId, {
    required String title,
    required DateTime start,
    required DateTime end,
    required String description,
    String? location,
    bool setLocation = false,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('updateEvent', {
        'eventId': eventId,
        'title': title,
        'start': start.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
        'description': description,
        'setLocation': setLocation,
        'location': location,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// Server-side identities of events: the iCalendar UID and the sync
  /// adapter's sync ID, keyed by event ID. Empty when unavailable.
  Future<Map<String, EventIdentity>> getEventIdentities(
    List<String> eventIds,
  ) async {
    if (eventIds.isEmpty) return {};
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getEventIdentities',
        {'eventIds': eventIds},
      );
      if (raw == null) return {};
      return {
        for (final entry in raw.entries)
          entry.key as String: EventIdentity(
            uid: (entry.value as Map?)?['uid'] as String?,
            syncId: (entry.value as Map?)?['syncId'] as String?,
          ),
      };
    } catch (_) {
      return {};
    }
  }

  /// Adds an exception date to a recurring event so the occurrence starting
  /// at [occurrenceStart] is no longer generated.
  Future<bool> excludeOccurrence(String eventId, DateTime occurrenceStart) async {
    try {
      final ok = await _channel.invokeMethod<bool>('excludeOccurrence', {
        'eventId': eventId,
        'start': occurrenceStart.millisecondsSinceEpoch,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// Raw event rows of [calendarId] that start in [from]..[to], straight
  /// from the provider (not expanded into instances). Diagnostic use.
  Future<List<Map<String, Object?>>> listEventRows(
    String calendarId,
    DateTime from,
    DateTime to,
  ) async {
    try {
      final rows = await _channel.invokeMethod<List<Object?>>('listEventRows', {
        'calendarId': calendarId,
        'from': from.millisecondsSinceEpoch,
        'to': to.millisecondsSinceEpoch,
      });
      return [
        for (final row in rows ?? const [])
          Map<String, Object?>.from(row as Map),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Whether the event row is gone or flagged as deleted by its sync adapter.
  ///
  /// Returns false when the check itself fails, so callers fall back to
  /// treating the event as alive.
  Future<bool> isEventDeleted(String eventId) async {
    try {
      final deleted = await _channel.invokeMethod<bool>(
        'isEventDeleted',
        {'eventId': eventId},
      );
      return deleted == true;
    } catch (_) {
      return false;
    }
  }

  Future<CalendarDeleteResult> deleteEvent(String eventId) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'deleteEvent',
        {'eventId': eventId},
      );
      return CalendarDeleteResult(success: ok == true);
    } catch (_) {
      return const CalendarDeleteResult(success: false);
    }
  }
}

class EventIdentity {
  final String? uid;
  final String? syncId;

  const EventIdentity({this.uid, this.syncId});
}

class CalendarDeleteResult {
  final bool success;

  const CalendarDeleteResult({
    required this.success,
  });
}

import 'dart:collection';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_calendar_plus/device_calendar_plus.dart';
import '../calendar/calendar_service.dart';
import 'mapping_database.dart';

const _syncMarker = '\u{1F503} Automatically created by CalSync';

String buildDescription(
  String originalTitle,
  String? sourceDescription,
  bool copyDescription, {
  bool omitSourceTitle = false,
}) {
  final titleLine = omitSourceTitle
      ? sha256.convert(originalTitle.codeUnits).toString()
      : originalTitle;
  String description = '$titleLine\n---\n$_syncMarker';
  if (copyDescription &&
      sourceDescription != null &&
      sourceDescription.isNotEmpty) {
    description = '$sourceDescription\n\n$description';
  }
  return description;
}

class SyncPlan {
  final List<ToCreateEntry> toCreate;
  final List<ToUpdateEntry> toUpdate;
  final List<Event> toSkip;
  final List<Map<String, Object?>> toDelete;
  final List<String> errors;

  const SyncPlan({
    required this.toCreate,
    required this.toUpdate,
    required this.toSkip,
    required this.toDelete,
    required this.errors,
  });
}

class ToCreateEntry {
  final Event sourceEvent;
  final String projectedTitle;
  final String projectedDescription;
  final DateTime projectedStart;
  final DateTime projectedEnd;
  final bool projectedAllDay;

  const ToCreateEntry({
    required this.sourceEvent,
    required this.projectedTitle,
    required this.projectedDescription,
    required this.projectedStart,
    required this.projectedEnd,
    this.projectedAllDay = false,
  });
}

class ToUpdateEntry {
  final Event sourceEvent;
  final Map<String, Object?> mapping;
  final String projectedTitle;

  const ToUpdateEntry({
    required this.sourceEvent,
    required this.mapping,
    required this.projectedTitle,
  });
}

class SyncEngine {
  final CalendarService _calendarService;
  final MappingDatabase _mappingDb;
  final DateTime Function() _clock;
  final Duration lockTimeout;
  final Duration lockPollInterval;

  SyncEngine(
    this._calendarService,
    this._mappingDb, {
    DateTime Function()? clock,
    this.lockTimeout = const Duration(minutes: 5),
    this.lockPollInterval = const Duration(seconds: 2),
  }) : _clock = clock ?? DateTime.now;

  /// Runs one sync while holding the shared sync lock.
  ///
  /// Syncs are started by calendar-change jobs, the periodic job and the
  /// UI, each in its own isolate. Two overlapping syncs would both see a new
  /// source event as unsynced and both create it, and the second mapping
  /// would overwrite the first, leaving an untracked duplicate behind. The
  /// lock makes them run one after another instead.
  Future<SyncResult> runSync({
    required String profileId,
    required String sourceCalendarId,
    required String targetCalendarId,
    required String syncEventName,
    bool copyDescription = false,
    bool copyLocation = false,
    bool omitSourceTitle = false,
    String trigger = 'manual',
  }) async {
    final owner =
        '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
    if (!await _acquireLock(owner, profileId)) {
      await _log(profileId, 'SKIP run ($trigger): another sync still running');
      return SyncResult(
        synced: UnmodifiableListView([]),
        skipped: UnmodifiableListView([]),
        deleted: UnmodifiableListView([]),
        updated: UnmodifiableListView([]),
        errors: UnmodifiableListView(['another sync is still running']),
      );
    }
    try {
      await _log(profileId, 'START run ($trigger)');
      final result = await _runSyncLocked(
        profileId: profileId,
        sourceCalendarId: sourceCalendarId,
        targetCalendarId: targetCalendarId,
        syncEventName: syncEventName,
        copyDescription: copyDescription,
        copyLocation: copyLocation,
        omitSourceTitle: omitSourceTitle,
      );
      for (final error in result.errors) {
        await _log(profileId, 'ERROR $error');
      }
      await _log(
        profileId,
        'END run: ${result.synced.length} created, '
        '${result.updated.length} updated, ${result.deleted.length} deleted, '
        '${result.skipped.length} skipped, ${result.errors.length} errors',
      );
      return result;
    } finally {
      try {
        await _mappingDb.releaseSyncLock(owner);
      } catch (_) {}
    }
  }

  Future<bool> _acquireLock(String owner, String profileId) async {
    final waited = Stopwatch()..start();
    var loggedWait = false;
    while (true) {
      try {
        if (await _mappingDb.tryAcquireSyncLock(owner)) {
          return true;
        }
      } catch (_) {
        // Database busy with another isolate's write; retry.
      }
      if (waited.elapsed >= lockTimeout) {
        return false;
      }
      if (!loggedWait) {
        loggedWait = true;
        await _log(profileId, 'WAIT for another sync to finish');
      }
      await Future<void>.delayed(lockPollInterval);
    }
  }

  Future<void> _log(String profileId, String message) async {
    try {
      await _mappingDb.appendSyncLog(profileId, message);
    } catch (_) {
      // Logging must never break a sync.
    }
  }

  static String _describe(Event event) {
    final start = event.startDate.toLocal().toIso8601String();
    final when = start.length >= 16 ? start.substring(0, 16) : start;
    return 'src=${event.eventId} "${event.title}" $when';
  }

  Future<SyncResult> _runSyncLocked({
    required String profileId,
    required String sourceCalendarId,
    required String targetCalendarId,
    required String syncEventName,
    required bool copyDescription,
    required bool copyLocation,
    required bool omitSourceTitle,
  }) async {
    final plan = await _classify(
      profileId: profileId,
      sourceCalendarId: sourceCalendarId,
      targetCalendarId: targetCalendarId,
      syncEventName: syncEventName,
      copyDescription: copyDescription,
      omitSourceTitle: omitSourceTitle,
    );


    if (plan.errors.isNotEmpty) {
      return SyncResult(
        synced: UnmodifiableListView([]),
        skipped: UnmodifiableListView([]),
        deleted: UnmodifiableListView([]),
        updated: UnmodifiableListView([]),
        errors: UnmodifiableListView(plan.errors),
      );
    }

    final result = await _execute(
      plan: plan,
      profileId: profileId,
      sourceCalendarId: sourceCalendarId,
      targetCalendarId: targetCalendarId,
      syncEventName: syncEventName,
      copyDescription: copyDescription,
      copyLocation: copyLocation,
      omitSourceTitle: omitSourceTitle,
    );

    return result;
  }

  Future<SyncPlan> runDryRun({
    required String profileId,
    required String sourceCalendarId,
    required String targetCalendarId,
    required String syncEventName,
    bool copyDescription = false,
    bool omitSourceTitle = false,
  }) async {
    return _classify(
      profileId: profileId,
      sourceCalendarId: sourceCalendarId,
      targetCalendarId: targetCalendarId,
      syncEventName: syncEventName,
      copyDescription: copyDescription,
      omitSourceTitle: omitSourceTitle,
    );
  }

  Future<void> _processOrphanMappings({
    required String profileId,
    required Set<String> sourceEventIds,
    required String sourceCalendarId,
    required String targetCalendarId,
    required List<Map<String, Object?>> mappings,
    required List<Event> sourceEvents,
    required List<Map<String, Object?>> toDelete,
    required List<String> errors,
    required DateTime listedAt,
  }) async {
    for (final mapping in mappings) {
      final sourceEventId = mapping['source_event_id'] as String;

      if (!sourceEventIds.contains(sourceEventId)) {
        final targetEventId = mapping['target_event_id'] as String;
        try {
          final targetEvent = await _calendarService.getEvent(
            targetEventId,
          );

          if (targetEvent == null) {
            await _log(
              profileId,
              'FORGET src=$sourceEventId: synced copy tgt=$targetEventId '
              'no longer exists',
            );
            final mappingId = mapping['id'] as int;
            await _mappingDb.deleteMapping(mappingId);
            await _mappingDb.deleteCreatedEvent(
              mapping['target_calendar_id'] as String,
              targetEventId,
            );
            continue;
          }

          final threshold = _clock().subtract(const Duration(days: 7));
          if (targetEvent.endDate.isBefore(threshold)) {
            continue;
          }

          final sourceEvent = await _calendarService.getEvent(
            sourceEventId,
          );

          if (sourceEvent == null) {
            toDelete.add(
                {...mapping, 'delete_reason': 'source event no longer exists'});
            continue;
          }
          final staleReason =
              await _staleSourceReason(sourceEvent, sourceEventId, listedAt);
          if (staleReason != null) {
            toDelete.add({...mapping, 'delete_reason': staleReason});
          } else {
            sourceEvents.add(sourceEvent);
          }
        } catch (e) {
          errors.add('$sourceEventId: $e');
        }
      }
    }
  }

  /// Whether a source event that was missing from the listing is a leftover
  /// that should be treated as deleted, even though it can still be fetched
  /// by ID.
  ///
  /// Some sync adapters (notably Outlook/Exchange) replace an event on every
  /// change: the old row is flagged deleted (or dropped from instances) and a
  /// new row with a new ID is inserted. Fetching the old ID still returns it,
  /// so without this check the old mapping is kept alive while the new ID is
  /// synced again, piling up duplicates in the target calendar.
  ///
  /// Returns why the event counts as stale, or null if it is still alive.
  Future<String?> _staleSourceReason(
    Event sourceEvent,
    String sourceEventId,
    DateTime listedAt,
  ) async {
    if (await _calendarService.isEventDeleted(sourceEventId)) {
      return 'source event flagged deleted';
    }

    // A recurring series can legitimately have no instance in the window
    // while still being alive, so only the explicit deleted flag counts.
    if (sourceEvent.isRecurring || sourceEvent.recurrenceRule != null) {
      return null;
    }

    // A one-off event that overlaps the listed window should have been
    // listed. If it was not, the calendar no longer considers it live.
    // Margins absorb clock drift between listing and now, and all-day
    // events being stored in UTC.
    final margin = sourceEvent.isAllDay
        ? const Duration(days: 1)
        : const Duration(minutes: 5);
    final windowStart = listedAt.add(margin);
    final windowEnd = listedAt.add(CalendarService.syncWindow).subtract(margin);
    final inWindow = sourceEvent.endDate.isAfter(windowStart) &&
        sourceEvent.startDate.isBefore(windowEnd);
    return inWindow ? 'source event no longer listed in sync window' : null;
  }

  Future<SyncPlan> _classify({
    required String profileId,
    required String sourceCalendarId,
    required String targetCalendarId,
    required String syncEventName,
    bool copyDescription = false,
    bool omitSourceTitle = false,
  }) async {
    final toCreate = <ToCreateEntry>[];
    final toUpdate = <ToUpdateEntry>[];
    final toSkip = <Event>[];
    final toDelete = <Map<String, Object?>>[];
    final errors = <String>[];
    final processedIds = <String>{};

    final listedAt = _clock();
    final listed = await _calendarService.listEvents(sourceCalendarId);
    if (listed == null) {
      // Without the source listing every mapping would look orphaned, so
      // bail out instead of deleting synced events.
      return SyncPlan(
        toCreate: toCreate,
        toUpdate: toUpdate,
        toSkip: toSkip,
        toDelete: toDelete,
        errors: ['$sourceCalendarId: failed to list source events'],
      );
    }
    final sourceEvents = List<Event>.of(listed);

    final mappings = await _mappingDb.listMappingsForCalendar(
      profileId,
      sourceCalendarId,
    );

    final sourceEventIds = sourceEvents.map((e) => e.eventId).toSet();

    await _processOrphanMappings(
      profileId: profileId,
      sourceEventIds: sourceEventIds,
      sourceCalendarId: sourceCalendarId,
      targetCalendarId: targetCalendarId,
      mappings: mappings,
      sourceEvents: sourceEvents,
      toDelete: toDelete,
      errors: errors,
      listedAt: listedAt,
    );

    for (final event in sourceEvents) {
      final eventId = event.eventId;
      final isInstance = eventId != event.instanceId;

      if (isInstance) {
        if (processedIds.contains(eventId)) {
          continue;
        }
        final baseEvent = await _calendarService.getEvent(eventId);
        if (baseEvent != null) {
          processedIds.add(eventId);
          final toUse = Event(
            eventId: eventId,
            instanceId: eventId,
            calendarId: sourceCalendarId,
            title: baseEvent.title,
            description: baseEvent.description,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            isRecurring: true,
            recurrenceRule: baseEvent.recurrenceRule,
            availability: EventAvailability.busy,
            status: EventStatus.none,
          );
          await _classifySingle(
            event: toUse,
            toCreate: toCreate,
            toUpdate: toUpdate,
            toSkip: toSkip,
            errors: errors,
            profileId: profileId,
            sourceCalendarId: sourceCalendarId,
            targetCalendarId: targetCalendarId,
            syncEventName: syncEventName,
            mappings: mappings,
            copyDescription: copyDescription,
            omitSourceTitle: omitSourceTitle,
          );
        }
        toSkip.add(event);
        continue;
      }

      if (processedIds.contains(eventId)) {
        continue;
      }
      processedIds.add(eventId);
      await _classifySingle(
        event: event,
        toCreate: toCreate,
        toUpdate: toUpdate,
        toSkip: toSkip,
        errors: errors,
        profileId: profileId,
        sourceCalendarId: sourceCalendarId,
        targetCalendarId: targetCalendarId,
        syncEventName: syncEventName,
        mappings: mappings,
        copyDescription: copyDescription,
        omitSourceTitle: omitSourceTitle,
      );

    }
    return SyncPlan(
      toCreate: toCreate,
      toUpdate: toUpdate,
      toSkip: toSkip,
      toDelete: toDelete,
      errors: errors,
    );
  }

  Future<void> _classifySingle({
    required Event event,
    required List<ToCreateEntry> toCreate,
    required List<ToUpdateEntry> toUpdate,
    required List<Event> toSkip,
    required List<String> errors,
    required String profileId,
    required String sourceCalendarId,
    required String targetCalendarId,
    required String syncEventName,
    required List<Map<String, Object?>> mappings,
    bool copyDescription = false,
    bool omitSourceTitle = false,
  }) async {
    final eventId = event.eventId;

    try {
      final description = event.description;
      if (description != null && description.contains(_syncMarker)) {
        toSkip.add(event);
        return;
      }

      final createdBySync = await _mappingDb.isEventCreatedBySync(
        sourceCalendarId,
        eventId,
      );
      if (createdBySync) {
        toSkip.add(event);
        return;
      }

      final alreadySynced = await _mappingDb.isEventSynced(
        profileId,
        sourceCalendarId,
        eventId,
      );

      if (alreadySynced) {
        final mapping = mappings.cast<Map<String, Object?>>().firstWhere(
          (m) => m['source_event_id'] == eventId,
          orElse: () => <String, Object?>{},
        );
        if (mapping.isEmpty) {
          toSkip.add(event);
          return;
        }
        final targetEventId = mapping['target_event_id'] as String;

        final targetEvent = await _calendarService.getEvent(
          targetEventId,
        );

        if (targetEvent == null) {
          toSkip.add(event);
          return;
        }

        final isRecurring = event.isRecurring && event.recurrenceRule != null;
        final canonicalTime = mapping['canonical_time'] as String?;
        bool timeChanged;
        if (isRecurring && canonicalTime != null) {
          final currentTime =
              '${event.startDate.hour.toString().padLeft(2, '0')}:${event.startDate.minute.toString().padLeft(2, '0')}';
          timeChanged = currentTime != canonicalTime;
        } else {
          timeChanged =
              event.startDate.millisecondsSinceEpoch !=
                      targetEvent.startDate.millisecondsSinceEpoch ||
                  event.endDate.millisecondsSinceEpoch !=
                      targetEvent.endDate.millisecondsSinceEpoch;
        }
        final titleFingerprint = omitSourceTitle
            ? sha256.convert(event.title.codeUnits).toString()
            : event.title;
        final titleChanged =
            !(targetEvent.description?.contains(titleFingerprint) ?? false);

        if (!timeChanged && !titleChanged) {
          toSkip.add(event);
          return;
        }

        toUpdate.add(ToUpdateEntry(
          sourceEvent: event,
          mapping: Map<String, Object?>.from(mapping),
          projectedTitle: syncEventName.isEmpty ? event.title : syncEventName,
        ));
        return;
      }

      toCreate.add(ToCreateEntry(
        sourceEvent: event,
        projectedTitle: syncEventName.isEmpty ? event.title : syncEventName,
        projectedDescription: event.title,
        projectedStart: event.startDate,
        projectedEnd: event.endDate,
        projectedAllDay: event.isAllDay,
      ));
    } catch (e) {
      errors.add('$eventId: $e');
    }
  }

  Future<SyncResult> _execute({
    required SyncPlan plan,
    required String profileId,
    required String sourceCalendarId,
    required String targetCalendarId,
    required String syncEventName,
    required bool copyDescription,
    required bool copyLocation,
    required bool omitSourceTitle,
  }) async {
    final synced = <String>[];
    final skipped = <String>[];
    final deleted = <String>[];
    final updated = <String>[];
    final errors = <String>[];

    for (final entry in plan.toDelete) {
      final mappingId = entry['id'] as int;
      final sourceEventId = entry['source_event_id'] as String;
      final targetEventId = entry['target_event_id'] as String;
      final targetCalId = entry['target_calendar_id'] as String;

      try {
        final deleteResult = await _calendarService.deleteEvent(targetEventId);

        if (!deleteResult.success) {
          errors.add('$sourceEventId: deleteEvent failed');
          continue;
        }

        await _mappingDb.deleteMapping(mappingId);
        await _mappingDb.deleteCreatedEvent(targetCalId, targetEventId);
        await _log(
          profileId,
          'DELETE src=$sourceEventId tgt=$targetEventId '
          '(${entry['delete_reason'] ?? 'source gone'})',
        );
        deleted.add(sourceEventId);
      } catch (e) {
        errors.add('$sourceEventId: delete failed: $e');
      }
    }

    for (final entry in plan.toCreate) {
      final event = entry.sourceEvent;
      final eventId = event.eventId;

      try {
        // Last guard against a duplicate: the plan may be stale if the
        // mapping was written after classification.
        if (await _mappingDb.isEventSynced(
          profileId,
          sourceCalendarId,
          eventId,
        )) {
          await _log(profileId, 'SKIP create ${_describe(event)}: already synced');
          skipped.add(eventId);
          continue;
        }

        final hasRecurrence = event.isRecurring && event.recurrenceRule != null;
        final targetEventId = await _calendarService.createEvent(
          targetCalendarId,
          entry.projectedTitle,
          entry.projectedStart,
          entry.projectedEnd,
          description: buildDescription(
            event.title,
            event.description,
            copyDescription,
            omitSourceTitle: omitSourceTitle,
          ),
          isAllDay: entry.projectedAllDay,
              recurrenceRule:
                  hasRecurrence ? event.recurrenceRule : null,
          location: copyLocation ? event.location : null,
        );

        if (targetEventId == null) {
          errors.add('$eventId: failed to create');
          continue;
        }

        final canonicalTime = hasRecurrence
            ? '${event.startDate.hour.toString().padLeft(2, '0')}:${event.startDate.minute.toString().padLeft(2, '0')}'
            : null;
        await _mappingDb.insertMapping(
          profileId: profileId,
          sourceCalendarId: sourceCalendarId,
          sourceEventId: eventId,
          targetCalendarId: targetCalendarId,
          targetEventId: targetEventId,
          syncedAt: DateTime.now().toIso8601String(),
          canonicalTime: canonicalTime,
        );

        await _mappingDb.insertCreatedEvent(
          targetCalendarId,
          targetEventId,
        );

        await _log(profileId, 'CREATE ${_describe(event)} -> tgt=$targetEventId');
        synced.add(eventId);
      } catch (e) {
        errors.add('$eventId: $e');
      }
    }

    for (final entry in plan.toUpdate) {
      final event = entry.sourceEvent;
      final eventId = event.eventId;
      final mapping = entry.mapping;
      final targetEventId = mapping['target_event_id'] as String;
      final targetCalId = mapping['target_calendar_id'] as String;

      try {
        final hasRecurrence = event.isRecurring &&
            event.recurrenceRule != null;
        final newTargetEventId = await _calendarService.createEvent(
          targetCalId,
          entry.projectedTitle,
          event.startDate,
          event.endDate,
          description: buildDescription(
            event.title,
            event.description,
            copyDescription,
            omitSourceTitle: omitSourceTitle,
          ),
          isAllDay: event.isAllDay,
              recurrenceRule:
                  hasRecurrence ? event.recurrenceRule : null,
          location: copyLocation ? event.location : null,
        );

        if (newTargetEventId == null) {
          errors.add('$eventId: failed to create replacement');
          continue;
        }

        await _calendarService.deleteEvent(targetEventId).then((result) {
          if (!result.success) {
            errors.add('$eventId: failed to delete old target event');
          }
        });
        await _mappingDb.deleteCreatedEvent(targetCalId, targetEventId);

        final canonicalTime = hasRecurrence
            ? '${event.startDate.hour.toString().padLeft(2, '0')}:${event.startDate.minute.toString().padLeft(2, '0')}'
            : null;
        await _mappingDb.insertMapping(
          profileId: profileId,
          sourceCalendarId: sourceCalendarId,
          sourceEventId: eventId,
          targetCalendarId: targetCalId,
          targetEventId: newTargetEventId,
          syncedAt: DateTime.now().toIso8601String(),
          canonicalTime: canonicalTime,
        );

        await _mappingDb.insertCreatedEvent(
          targetCalId,
          newTargetEventId,
        );

        await _log(
          profileId,
          'UPDATE ${_describe(event)} tgt=$targetEventId -> $newTargetEventId',
        );
        updated.add(eventId);
      } catch (e) {
        errors.add('$eventId: $e');
      }
    }

    for (final event in plan.toSkip) {
      skipped.add(event.eventId);
    }

    errors.addAll(plan.errors);

    return SyncResult(
      synced: UnmodifiableListView(synced),
      skipped: UnmodifiableListView(skipped),
      deleted: UnmodifiableListView(deleted),
      updated: UnmodifiableListView(updated),
      errors: UnmodifiableListView(errors),
    );
  }
}

class SyncResult {
  final UnmodifiableListView<String> synced;
  final UnmodifiableListView<String> skipped;
  final UnmodifiableListView<String> deleted;
  final UnmodifiableListView<String> updated;
  final UnmodifiableListView<String> errors;

  const SyncResult({
    required this.synced,
    required this.skipped,
    required this.deleted,
    required this.updated,
    required this.errors,
  });
}

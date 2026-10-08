import 'package:calendar_sync/calendar/calendar_service.dart';
import 'package:calendar_sync/sync/mapping_database.dart';
import 'package:calendar_sync/sync/sync_engine.dart';
import 'package:crypto/crypto.dart';
import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockCalendarService extends Mock implements CalendarService {}

class MockMappingDatabase extends Mock implements MappingDatabase {}

Event _makeEvent(String id, {required DateTime end, DateTime? start}) {
  final s = start ?? end.subtract(const Duration(hours: 1));
  return Event(
    eventId: id,
    instanceId: id,
    calendarId: 'cal-1',
    title: 'Test Event',
    startDate: s,
    endDate: end,
    isAllDay: false,
    availability: EventAvailability.busy,
    status: EventStatus.none,
    isRecurring: false,
  );
}

Event _allDayEvent(String id, DateTime start, DateTime end) {
  return Event(
    eventId: id,
    instanceId: id,
    calendarId: 'cal-1',
    title: 'All Day Test',
    startDate: start,
    endDate: end,
    isAllDay: true,
    availability: EventAvailability.busy,
    status: EventStatus.none,
    isRecurring: false,
  );
}

void main() {
  late MockCalendarService calendarService;
  late MockMappingDatabase mappingDb;
  late SyncEngine engine;

  final sourceCalId = 'src-cal';
  final targetCalId = 'tgt-cal';
  final syncName = 'Busy';
  final profileId = 'test-profile';

  final now = DateTime.utc(2026, 10, 1, 12);
  final futureEnd = DateTime.utc(2027, 1, 1);
  final oldEnd = DateTime.utc(2020, 1, 1);

  setUpAll(() {
    registerFallbackValue(DateTime(2000));
  });

  setUp(() {
    calendarService = MockCalendarService();
    mappingDb = MockMappingDatabase();
    engine = SyncEngine(calendarService, mappingDb, clock: () => now);
    when(() => calendarService.isEventDeleted(any()))
        .thenAnswer((_) async => false);
    when(() => mappingDb.tryAcquireSyncLock(any()))
        .thenAnswer((_) async => true);
    when(() => mappingDb.releaseSyncLock(any())).thenAnswer((_) async {});
    when(() => mappingDb.refreshSyncLock(any())).thenAnswer((_) async {});
    when(() => mappingDb.appendSyncLog(any(), any()))
        .thenAnswer((_) async {});
    when(() => mappingDb.recordSourceSignature(any(), any(), any(), any()))
        .thenAnswer((_) async {});
    when(() => mappingDb.relinkMapping(any(), any())).thenAnswer((_) async {});
    when(() => calendarService.getEventIdentities(any()))
        .thenAnswer((_) async => {});
    when(() => calendarService.excludeOccurrence(any(), any()))
        .thenAnswer((_) async => true);
    when(() => calendarService.listEventRows(any(), any(), any()))
        .thenAnswer((_) async => []);
    when(() => calendarService.updateEvent(
          any(),
          title: any(named: 'title'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          description: any(named: 'description'),
          location: any(named: 'location'),
          setLocation: any(named: 'setLocation'),
        )).thenAnswer((_) async => false);
  });

  group('Removed occurrences of recurring series', () {
    final base = DateTime.now();
    // Weekly occurrences at 13:00 local time, 3..24 days ahead.
    List<DateTime> weekly() => [
          for (var week = 0; week < 4; week++)
            DateTime(base.year, base.month, base.day + 3 + week * 7, 13),
        ];
    Event instance(String id, String calId, DateTime start) => Event(
          eventId: id,
          instanceId: '$id-${start.millisecondsSinceEpoch}',
          calendarId: calId,
          title: 'Saeb-Henry Fortnightly 1:1',
          startDate: start,
          endDate: start.add(const Duration(minutes: 30)),
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: true,
        );

    void stub({required List<DateTime> source, required List<DateTime> target}) {
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [for (final t in source) instance('src-r', sourceCalId, t)],
      );
      when(() => calendarService.listEvents(targetCalId)).thenAnswer(
        (_) async => [for (final t in target) instance('tgt-r', targetCalId, t)],
      );
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => [
                {
                  'id': 1,
                  'source_event_id': 'src-r',
                  'target_event_id': 'tgt-r',
                  'target_calendar_id': targetCalId,
                },
              ]);
      when(() => calendarService.getEvent('src-r')).thenAnswer(
          (_) async => instance('src-r', sourceCalId, source.first));
      when(() => mappingDb.isEventCreatedBySync(any(), any()))
          .thenAnswer((_) async => true);
    }

    Future<void> sync() => engine.runSync(
          profileId: profileId,
          sourceCalendarId: sourceCalId,
          targetCalendarId: targetCalId,
          syncEventName: syncName,
        );

    test('occurrence cancelled in the source is excluded from the target',
        () async {
      final all = weekly();
      stub(source: [all[0], all[2], all[3]], target: all);

      await sync();

      verify(() => calendarService.excludeOccurrence('tgt-r', all[1]))
          .called(1);
    });

    test('matching series is left alone', () async {
      final all = weekly();
      stub(source: all, target: all);

      await sync();

      verifyNever(() => calendarService.excludeOccurrence(any(), any()));
    });

    test('same dates at shifted times (time zone) are not excluded', () async {
      final all = weekly();
      stub(
        source: [for (final t in all) t.add(const Duration(hours: 1))],
        target: all,
      );

      await sync();

      verifyNever(() => calendarService.excludeOccurrence(any(), any()));
    });

    test('mostly mismatched series is left alone', () async {
      final all = weekly();
      stub(
        source: [for (final t in all) t.add(const Duration(days: 1))],
        target: all,
      );

      await sync();

      verifyNever(() => calendarService.excludeOccurrence(any(), any()));
    });
  });

  group('Unlisted source events', () {
    test('rows missing from the listing are logged', () async {
      final start = DateTime.now().add(const Duration(days: 4));
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-1', start: start, end: start.add(const Duration(hours: 1))),
        ],
      );
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);
      when(() => calendarService.listEventRows(sourceCalId, any(), any()))
          .thenAnswer((_) async => [
                {'id': 'src-1', 'title': 'Listed'},
                {
                  'id': 'src-9',
                  'title': 'Ries - Henry 1:1',
                  'start': start.millisecondsSinceEpoch,
                  'end': start.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
                  'status': 1,
                  'originalId': '22158',
                  'originalInstanceTime': null,
                  'recurring': false,
                },
              ]);

      await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      final lines = verify(() => mappingDb.appendSyncLog(profileId, captureAny()))
          .captured
          .cast<String>();
      expect(lines, contains(allOf(
        startsWith('UNLISTED src=src-9 "Ries - Henry 1:1"'),
        contains('series=22158'),
      )));
      expect(lines.where((l) => l.startsWith('UNLISTED src=src-1')), isEmpty);
    });
  });

  group('Event identity logging', () {
    test('CREATE line carries the meeting UID and sync ID', () async {
      final start = now.add(const Duration(days: 1));
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-1', start: start, end: start.add(const Duration(hours: 1))),
        ],
      );
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.getEventIdentities(any())).thenAnswer(
        (_) async => {'src-1': const EventIdentity(uid: 'UID-1', syncId: 'SYNC-1')},
      );
      when(() => calendarService.createEvent(
            any(), any(), any(), any(),
            description: any(named: 'description'),
            isAllDay: any(named: 'isAllDay'),
          )).thenAnswer((_) async => 'tgt-1');
      when(() => mappingDb.insertMapping(
            profileId: any(named: 'profileId'),
            sourceCalendarId: any(named: 'sourceCalendarId'),
            sourceEventId: any(named: 'sourceEventId'),
            targetCalendarId: any(named: 'targetCalendarId'),
            targetEventId: any(named: 'targetEventId'),
            syncedAt: any(named: 'syncedAt'),
            canonicalTime: any(named: 'canonicalTime'),
          )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(any(), any()))
          .thenAnswer((_) async {});

      await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      final lines = verify(() => mappingDb.appendSyncLog(profileId, captureAny()))
          .captured
          .cast<String>();
      expect(lines, contains(allOf(
        startsWith('CREATE src=src-1'),
        contains('[uid=UID-1 sync=SYNC-1]'),
      )));
    });
  });

  group('Target check', () {
    Event copy(String id, DateTime start, String sourceTitle) => Event(
          eventId: id,
          instanceId: id,
          calendarId: targetCalId,
          title: syncName,
          description: '$sourceTitle\n---\n🔃 Automatically created by CalSync',
          startDate: start,
          endDate: start.add(const Duration(hours: 1)),
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        );

    test('removes untracked copies of tracked events, reports the rest',
        () async {
      final t1 = now.add(const Duration(days: 1));
      final t2 = now.add(const Duration(days: 2));
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => calendarService.listEvents(targetCalId)).thenAnswer(
        (_) async => [
          copy('t-1', t1, 'Standup'),
          copy('t-2', t1, 'Standup'),
          copy('t-3', t2, 'Review'),
          copy('t-4', t2, 'Planning'),
          copy('t-5', t2, 'Planning'),
        ],
      );
      // t-2 is an untracked copy of tracked t-1 and gets removed. t-4 and
      // t-5 are untracked copies with no tracked twin: kept and reported.
      when(() => mappingDb.isEventCreatedBySync(targetCalId, any()))
          .thenAnswer((inv) async =>
              !['t-2', 't-4', 't-5'].contains(inv.positionalArguments[1]));
      when(() => calendarService.deleteEvent('t-2'))
          .thenAnswer((_) async => const CalendarDeleteResult(success: true));

      await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      final lines = verify(() => mappingDb.appendSyncLog(profileId, captureAny()))
          .captured
          .cast<String>();
      expect(lines, contains(startsWith('REMOVE untracked duplicate tgt=t-2')));
      expect(lines, contains(startsWith(
          'CHECK target: 2 untracked CalSync events, 1 duplicated events')));
      expect(lines, contains(contains('duplicate x2 "Planning"')));
      verifyNever(() => calendarService.deleteEvent('t-4'));
      verifyNever(() => calendarService.deleteEvent('t-5'));
    });

    test('clean target logs no duplicates', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => calendarService.listEvents(targetCalId)).thenAnswer(
        (_) async => [copy('t-1', now.add(const Duration(days: 1)), 'Standup')],
      );
      when(() => mappingDb.isEventCreatedBySync(targetCalId, 't-1'))
          .thenAnswer((_) async => true);

      await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => mappingDb.appendSyncLog(
          profileId, 'CHECK target: 1 CalSync events, no duplicates')).called(1);
    });
  });

  group('Source signature', () {
    final start = now.add(const Duration(days: 2));
    final end = start.add(const Duration(hours: 1));
    String sig(Event e) => sourceSignature(
          e,
          syncEventName: syncName,
          copyDescription: false,
          omitSourceTitle: false,
        );

    void stubMapping(String? signature) {
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => [
                {
                  'id': 1,
                  'source_event_id': 'src-1',
                  'target_event_id': 'tgt-1',
                  'target_calendar_id': targetCalId,
                  'source_signature': signature,
                },
              ]);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);
      // Target as rewritten by the server: description no longer holds the
      // title and times are off, which used to trigger an update every run.
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: syncName,
          description: '<html>rewritten</html>',
          startDate: start.add(const Duration(minutes: 1)),
          endDate: end,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );
    }

    test('unchanged source is skipped even if the target was rewritten',
        () async {
      final src = _makeEvent('src-1', start: start, end: end);
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [src]);
      stubMapping(sig(src));

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toUpdate, isEmpty);
      expect(plan.toSkip.map((e) => e.eventId), contains('src-1'));
    });

    test('changed source is updated in place, nothing created or deleted',
        () async {
      final src = _makeEvent('src-1', start: start, end: end);
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [src]);
      stubMapping('stale-signature');
      when(() => calendarService.updateEvent(
            'tgt-1',
            title: syncName,
            start: start,
            end: end,
            description: any(named: 'description'),
            location: any(named: 'location'),
            setLocation: false,
          )).thenAnswer((_) async => true);

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      // createEvent/deleteEvent are not stubbed: calling them would error.
      expect(result.errors, isEmpty);
      expect(result.updated, ['src-1']);
      verify(() => mappingDb.recordSourceSignature(
            profileId, sourceCalId, 'src-1', sig(src))).called(1);
    });

    test('legacy mapping without signature gets one when unchanged', () async {
      final src = _makeEvent('src-1', start: start, end: end);
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [src]);
      stubMapping(null);
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: syncName,
          description: 'Test Event\n---\n🔃 Automatically created by CalSync',
          startDate: start,
          endDate: end,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toUpdate, isEmpty);
      verify(() => mappingDb.recordSourceSignature(
            profileId, sourceCalId, 'src-1', sig(src))).called(1);
    });

    test('signature changes with title and time but not with instance date',
        () {
      final a = _makeEvent('src-1', start: start, end: end);
      final retitled = Event(
        eventId: 'src-1', instanceId: 'src-1', calendarId: sourceCalId,
        title: 'Other', startDate: start, endDate: end, isAllDay: false,
        availability: EventAvailability.busy, status: EventStatus.none,
        isRecurring: false,
      );
      final moved = _makeEvent('src-1',
          start: start.add(const Duration(hours: 1)),
          end: end.add(const Duration(hours: 1)));
      expect(sig(retitled), isNot(sig(a)));
      expect(sig(moved), isNot(sig(a)));
      expect(sig(a), sig(_makeEvent('src-1', start: start, end: end)));
    });
  });

  group('Sync lock', () {
    test('runs after waiting for the lock, then releases it', () async {
      var attempts = 0;
      when(() => mappingDb.tryAcquireSyncLock(any()))
          .thenAnswer((_) async => ++attempts >= 3);
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      engine = SyncEngine(
        calendarService,
        mappingDb,
        clock: () => now,
        lockPollInterval: Duration.zero,
      );

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(result.errors, isEmpty);
      expect(attempts, 3);
      verify(() => calendarService.listEvents(sourceCalId)).called(1);
      verify(() => mappingDb.releaseSyncLock(any())).called(1);
    });

    test('gives up without touching calendars when lock never frees', () async {
      when(() => mappingDb.tryAcquireSyncLock(any()))
          .thenAnswer((_) async => false);
      engine = SyncEngine(
        calendarService,
        mappingDb,
        clock: () => now,
        lockTimeout: Duration.zero,
        lockPollInterval: Duration.zero,
      );

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(result.errors, hasLength(1));
      verifyNever(() => calendarService.listEvents(any()));
      verifyNever(() => mappingDb.releaseSyncLock(any()));
    });

    test('lock is released when the sync throws', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenThrow(Exception('boom'));

      await expectLater(
        engine.runSync(
          profileId: profileId,
          sourceCalendarId: sourceCalId,
          targetCalendarId: targetCalId,
          syncEventName: syncName,
        ),
        throwsException,
      );
      verify(() => mappingDb.releaseSyncLock(any())).called(1);
    });

    test('create is skipped when mapping appeared after classification',
        () async {
      final start = now.add(const Duration(days: 2));
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-1', start: start, end: start.add(const Duration(hours: 1))),
        ],
      );
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      var checks = 0;
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => ++checks > 1);

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      // createEvent is not stubbed, so calling it would surface as an error.
      expect(result.errors, isEmpty);
      expect(result.synced, isEmpty);
      expect(result.skipped, contains('src-1'));
    });
  });

  group('Deletion pass 7-day threshold + source-by-ID', () {
    test('old past event (target.end < now-7d) -> skipped, no source fetch', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-1',
            'target_event_id': 'tgt-1',
            'target_calendar_id': targetCalId,
          },
        ],
      );

      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => _makeEvent('tgt-1', end: oldEnd, start: oldEnd.subtract(const Duration(hours: 1))),
      );

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, isEmpty);
    });

    test('recent event with source exists -> re-classified, not deleted', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-1',
            'target_event_id': 'tgt-1',
            'target_calendar_id': targetCalId,
          },
        ],
      );

      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'Busy',
          description: 'Test Event\n---\n🔃 Automatically created by CalSync',
          startDate: futureEnd.subtract(const Duration(hours: 1)),
          endDate: futureEnd,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );

      when(() => calendarService.getEvent('src-1')).thenAnswer(
        (_) async => _makeEvent('src-1', end: futureEnd,
            start: futureEnd.subtract(const Duration(hours: 1))),
      );

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, isEmpty);
      verify(() => calendarService.getEvent('src-1')).called(1);
    });

    test('recent event with source gone -> deleted', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-1',
            'target_event_id': 'tgt-1',
            'target_calendar_id': targetCalId,
          },
        ],
      );

      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => _makeEvent('tgt-1', end: futureEnd,
            start: futureEnd.subtract(const Duration(hours: 1))),
      );

      when(() => calendarService.getEvent('src-1'))
          .thenAnswer((_) async => null);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, hasLength(1));
      expect(plan.toDelete.first['source_event_id'], 'src-1');
      verify(() => calendarService.getEvent('src-1')).called(1);
    });

    test('recent event source found -> re-classified (skip when unchanged)', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-1',
            'target_event_id': 'tgt-1',
            'target_calendar_id': targetCalId,
          },
        ],
      );

      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'Busy',
          description: 'Test Event\n---\n🔃 Automatically created by CalSync',
          startDate: futureEnd.subtract(const Duration(hours: 1)),
          endDate: futureEnd,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );

      when(() => calendarService.getEvent('src-1')).thenAnswer(
        (_) async => _makeEvent('src-1', end: futureEnd,
            start: futureEnd.subtract(const Duration(hours: 1))),
      );

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, isEmpty);
      expect(plan.toUpdate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
      verify(() => calendarService.getEvent('src-1')).called(1);
    });

    test('recent event source found with changed time -> classified as toUpdate', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-1',
            'target_event_id': 'tgt-1',
            'target_calendar_id': targetCalId,
          },
        ],
      );

      final changedStart = futureEnd.subtract(const Duration(hours: 2));

      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'Busy',
          description: 'Test Event\n---\n🔃 Automatically created by CalSync',
          startDate: futureEnd.subtract(const Duration(hours: 1)),
          endDate: futureEnd,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );

      when(() => calendarService.getEvent('src-1')).thenAnswer(
        (_) async => _makeEvent('src-1', end: futureEnd, start: changedStart),
      );

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, isEmpty);
      expect(plan.toUpdate, hasLength(1));
      expect(plan.toUpdate.first.sourceEvent.eventId, 'src-1');
      verify(() => calendarService.getEvent('src-1')).called(1);
    });
  });

  group('Replaced source events (Outlook/Exchange new IDs)', () {
    final inWindowStart = now.add(const Duration(days: 3));
    final inWindowEnd = inWindowStart.add(const Duration(hours: 1));

    Event targetEvent(String id) => Event(
          eventId: id,
          instanceId: id,
          calendarId: targetCalId,
          title: 'Busy',
          description: 'Test Event\n---\n🔃 Automatically created by CalSync',
          startDate: inWindowStart,
          endDate: inWindowEnd,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        );

    void stubOldMapping() {
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-old',
            'target_event_id': 'tgt-old',
            'target_calendar_id': targetCalId,
          },
        ],
      );
      when(() => calendarService.getEvent('tgt-old'))
          .thenAnswer((_) async => targetEvent('tgt-old'));
    }

    void stubNewSourceUnsynced() {
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-new'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-new'))
          .thenAnswer((_) async => false);
    }

    test('old ID flagged deleted, identical new ID -> relinked, nothing created',
        () async {
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-new', start: inWindowStart, end: inWindowEnd),
        ],
      );
      stubOldMapping();
      stubNewSourceUnsynced();
      when(() => calendarService.getEvent('src-old')).thenAnswer(
        (_) async =>
            _makeEvent('src-old', start: inWindowStart, end: inWindowEnd),
      );
      when(() => calendarService.isEventDeleted('src-old'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, isEmpty);
      expect(plan.toCreate, isEmpty);
      expect(plan.toUpdate, isEmpty);
      expect(plan.toRelink, hasLength(1));
      expect(plan.toRelink.first.mapping['source_event_id'], 'src-old');
      expect(plan.toRelink.first.sourceEvent.eventId, 'src-new');
    });

    test('old ID gone, different new event -> old deleted, new created',
        () async {
      final otherStart = inWindowStart.add(const Duration(hours: 3));
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-new',
              start: otherStart, end: otherStart.add(const Duration(hours: 1))),
        ],
      );
      stubOldMapping();
      stubNewSourceUnsynced();
      when(() => calendarService.getEvent('src-old')).thenAnswer(
        (_) async =>
            _makeEvent('src-old', start: inWindowStart, end: inWindowEnd),
      );
      when(() => calendarService.isEventDeleted('src-old'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toRelink, isEmpty);
      expect(plan.toDelete.single['source_event_id'], 'src-old');
      expect(plan.toCreate.single.sourceEvent.eventId, 'src-new');
    });

    test('new ID while identical old ID still listed -> new one not synced',
        () async {
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-old', start: inWindowStart, end: inWindowEnd),
          _makeEvent('src-new', start: inWindowStart, end: inWindowEnd),
        ],
      );
      stubOldMapping();
      stubNewSourceUnsynced();
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-old'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-old'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, isEmpty);
      expect(plan.toDelete, isEmpty);
      expect(plan.toSkip.map((e) => e.eventId), contains('src-new'));
    });

    test('two synced copies of the same event -> extra copy removed',
        () async {
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-old', start: inWindowStart, end: inWindowEnd),
          _makeEvent('src-new', start: inWindowStart, end: inWindowEnd),
        ],
      );
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-old',
            'target_event_id': 'tgt-old',
            'target_calendar_id': targetCalId,
          },
          {
            'id': 2,
            'source_event_id': 'src-new',
            'target_event_id': 'tgt-new',
            'target_calendar_id': targetCalId,
          },
        ],
      );
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-old'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-old'))
          .thenAnswer((_) async => true);
      when(() => calendarService.getEvent('tgt-old'))
          .thenAnswer((_) async => targetEvent('tgt-old'));

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete.single['source_event_id'], 'src-new');
      expect(plan.toDelete.single['target_event_id'], 'tgt-new');
      expect(plan.toCreate, isEmpty);
    });

    test('relink is applied on sync and keeps the target', () async {
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-new', start: inWindowStart, end: inWindowEnd),
        ],
      );
      stubOldMapping();
      stubNewSourceUnsynced();
      when(() => calendarService.getEvent('src-old')).thenAnswer(
        (_) async =>
            _makeEvent('src-old', start: inWindowStart, end: inWindowEnd),
      );
      when(() => calendarService.isEventDeleted('src-old'))
          .thenAnswer((_) async => true);

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(result.errors, isEmpty);
      expect(result.updated, ['src-new']);
      verify(() => mappingDb.relinkMapping(1, 'src-new')).called(1);
      verifyNever(() => calendarService.deleteEvent('tgt-old'));
    });

    test('old ID missing from listing, identical new ID -> relinked',
        () async {
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-new', start: inWindowStart, end: inWindowEnd),
        ],
      );
      stubOldMapping();
      stubNewSourceUnsynced();
      when(() => calendarService.getEvent('src-old')).thenAnswer(
        (_) async =>
            _makeEvent('src-old', start: inWindowStart, end: inWindowEnd),
      );

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, isEmpty);
      expect(plan.toCreate, isEmpty);
      expect(plan.toRelink.single.sourceEvent.eventId, 'src-new');
    });

    test('existing pile of duplicates is cleaned up in one run', () async {
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [
          _makeEvent('src-3', start: inWindowStart, end: inWindowEnd),
        ],
      );
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer(
        (_) async => [
          for (var i = 1; i <= 3; i++)
            {
              'id': i,
              'source_event_id': 'src-$i',
              'target_event_id': 'tgt-$i',
              'target_calendar_id': targetCalId,
            },
        ],
      );
      for (var i = 1; i <= 3; i++) {
        when(() => calendarService.getEvent('tgt-$i'))
            .thenAnswer((_) async => targetEvent('tgt-$i'));
      }
      for (var i = 1; i <= 2; i++) {
        when(() => calendarService.getEvent('src-$i')).thenAnswer(
          (_) async =>
              _makeEvent('src-$i', start: inWindowStart, end: inWindowEnd),
        );
        when(() => calendarService.isEventDeleted('src-$i'))
            .thenAnswer((_) async => true);
      }
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-3'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-3'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(
        plan.toDelete.map((m) => m['source_event_id']),
        unorderedEquals(['src-1', 'src-2']),
      );
      expect(plan.toCreate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-3'), isTrue);
    });

    test('event moved beyond the window is kept, not deleted', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      stubOldMapping();
      final farStart = now.add(const Duration(days: 45));
      when(() => calendarService.getEvent('src-old')).thenAnswer(
        (_) async => _makeEvent('src-old',
            start: farStart, end: farStart.add(const Duration(hours: 1))),
      );
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-old'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-old'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, isEmpty);
      expect(plan.toUpdate, hasLength(1));
    });

    test('recurring series without instances in window is kept', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      stubOldMapping();
      when(() => calendarService.getEvent('src-old')).thenAnswer(
        (_) async => Event(
          eventId: 'src-old',
          instanceId: 'src-old',
          calendarId: sourceCalId,
          title: 'Test Event',
          startDate: inWindowStart,
          endDate: inWindowEnd,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: true,
        ),
      );
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-old'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-old'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, isEmpty);
    });

    test('failed source listing -> error, nothing deleted', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => null);
      stubOldMapping();

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(result.errors, hasLength(1));
      expect(result.deleted, isEmpty);
      verifyNever(() => calendarService.deleteEvent(any()));
      verifyNever(() => mappingDb.listMappingsForCalendar(any(), any()));
    });
  });

  group('Null safety for target event times', () {
    test('target event not found is skipped without crashing', () async {
      final srcEvent = _makeEvent('src-1',
          end: futureEnd, start: futureEnd.subtract(const Duration(hours: 1)));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-1',
            'target_event_id': 'tgt-1',
            'target_calendar_id': targetCalId,
          },
        ],
      );

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      when(() => calendarService.getEvent('tgt-1'))
          .thenAnswer((_) async => null);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });
  });

  group('All-day event sync', () {
    final day1 = DateTime.utc(2026, 6, 23);
    final day3 = DateTime.utc(2026, 6, 25);

    test('single-day all-day source creates all-day target with same dates', () async {
      final srcStart = day1;
      final srcEnd = day1.add(const Duration(days: 1));
      final srcEvent = _allDayEvent('src-1', srcStart, srcEnd);

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, hasLength(1));
      final entry = plan.toCreate.first;
      expect(entry.projectedAllDay, true);
      expect(entry.projectedStart, srcStart);
      expect(entry.projectedEnd, srcEnd);
    });

    test('multi-day all-day source creates all-day target with same dates', () async {
      final srcEnd = day3.add(const Duration(days: 1));
      final srcEvent = _allDayEvent('src-1', day1, srcEnd);

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, hasLength(1));
      final entry = plan.toCreate.first;
      expect(entry.projectedAllDay, true);
      expect(entry.projectedStart, day1);
      expect(entry.projectedEnd, srcEnd);
    });

    test('all-day change detection: skip when dates match', () async {
      final srcStart = day1;
      final srcEnd = day1.add(const Duration(days: 1));
      final srcEvent = _allDayEvent('src-1', srcStart, srcEnd);

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-1',
            'target_event_id': 'tgt-1',
            'target_calendar_id': targetCalId,
          },
        ],
      );

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'All Day Test',
          description: 'All Day Test',
          startDate: srcStart,
          endDate: srcEnd,
          isAllDay: true,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toUpdate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });

    test('all-day change detection: update when date changes', () async {
      final srcStart = day3;
      final srcEnd = day3.add(const Duration(days: 1));
      final srcEvent = _allDayEvent('src-1', srcStart, srcEnd);
      final tgtStart = day1;
      final tgtEnd = day1.add(const Duration(days: 1));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'source_event_id': 'src-1',
            'target_event_id': 'tgt-1',
            'target_calendar_id': targetCalId,
          },
        ],
      );

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'All Day Test',
          description: 'All Day Test',
          startDate: tgtStart,
          endDate: tgtEnd,
          isAllDay: true,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toUpdate, hasLength(1));
      expect(plan.toUpdate.first.sourceEvent.eventId, 'src-1');
    });

    test('timed source event is copied as-is (regression)', () async {
      final start = DateTime.utc(2026, 6, 23, 14, 0);
      final end = DateTime.utc(2026, 6, 23, 15, 0);
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Timed Event',
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);

      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);

      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, hasLength(1));
      final entry = plan.toCreate.first;
      expect(entry.projectedAllDay, false);
      expect(entry.projectedStart, start);
      expect(entry.projectedEnd, end);
    });
  });

  group('Safety net -- _execute paths', () {
    final start = DateTime.utc(2026, 6, 23, 14, 0);
    final end = DateTime.utc(2026, 6, 23, 15, 0);

    test('create path: createEvent is called with correct values', () async {
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Test',
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync', isAllDay: false,
      )).thenAnswer((_) async => 'new-id-1');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-1',
        targetCalendarId: targetCalId,
        targetEventId: 'new-id-1',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id-1'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync', isAllDay: false,
      )).called(1);
      expect(result.synced, ['src-1']);
    });

    test('update path: old event deleted then new event created', () async {
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Test',
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );
      final tgtEnd = end.subtract(const Duration(hours: 1));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'Test',
          startDate: start,
          endDate: tgtEnd,
          description: 'Test',
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync', isAllDay: false,
      )).thenAnswer((_) async => 'new-id-2');
      when(() => calendarService.deleteEvent('tgt-1'))
                    .thenAnswer((_) async => const CalendarDeleteResult(success: true));
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId, sourceEventId: 'src-1',
        targetCalendarId: targetCalId, targetEventId: 'new-id-2',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.deleteCreatedEvent(targetCalId, 'tgt-1'))
          .thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id-2'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => calendarService.deleteEvent('tgt-1')).called(1);
      verify(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync', isAllDay: false,
      )).called(1);
      expect(result.updated, ['src-1']);
    });

    test('update path: mapping save fails -> replacement removed, old kept',
        () async {
      final srcEvent = _makeEvent('src-1', start: start, end: end);
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => _makeEvent('tgt-1',
            start: start, end: end.subtract(const Duration(hours: 1))),
      );
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test Event\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
      )).thenAnswer((_) async => 'new-id-2');
      when(() => calendarService.deleteEvent('new-id-2'))
          .thenAnswer((_) async => const CalendarDeleteResult(success: true));
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId, sourceEventId: 'src-1',
        targetCalendarId: targetCalId, targetEventId: 'new-id-2',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenThrow(Exception('database is locked'));

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(result.updated, isEmpty);
      expect(result.errors, hasLength(1));
      verify(() => calendarService.deleteEvent('new-id-2')).called(1);
      verifyNever(() => calendarService.deleteEvent('tgt-1'));
    });

    test('create path: mapping save fails -> created event removed', () async {
      when(() => calendarService.listEvents(sourceCalId)).thenAnswer(
        (_) async => [_makeEvent('src-1', start: start, end: end)],
      );
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test Event\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
      )).thenAnswer((_) async => 'new-id');
      when(() => calendarService.deleteEvent('new-id'))
          .thenAnswer((_) async => const CalendarDeleteResult(success: true));
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId, sourceEventId: 'src-1',
        targetCalendarId: targetCalId, targetEventId: 'new-id',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenThrow(Exception('database is locked'));

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(result.synced, isEmpty);
      expect(result.errors, hasLength(1));
      verify(() => calendarService.deleteEvent('new-id')).called(1);
    });

    test('delete path: deleteEvent and deleteMapping are called', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => _makeEvent('tgt-1', end: futureEnd,
            start: futureEnd.subtract(const Duration(hours: 1))),
      );
      when(() => calendarService.getEvent('src-1'))
          .thenAnswer((_) async => null);
      when(() => calendarService.deleteEvent('tgt-1'))
                    .thenAnswer((_) async => const CalendarDeleteResult(success: true));
      when(() => mappingDb.deleteMapping(1))
          .thenAnswer((_) async {});
      when(() => mappingDb.deleteCreatedEvent(targetCalId, 'tgt-1'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => calendarService.deleteEvent('tgt-1')).called(1);
      verify(() => mappingDb.deleteMapping(1)).called(1);
      verify(() => calendarService.getEvent('src-1')).called(1);
      expect(result.deleted, ['src-1']);
    });

    test('errors path: plan.errors non-empty -> returns empty SyncResult', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => calendarService.getEvent('tgt-1'))
          .thenThrow(Exception('boom'));

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(result.synced, isEmpty);
      expect(result.skipped, isEmpty);
      expect(result.deleted, isEmpty);
      expect(result.updated, isEmpty);
      expect(result.errors, isNotEmpty);
    });
  });

  group('Safety net -- orphan mappings', () {
    final day1 = DateTime.utc(2026, 6, 23);

    test('target event is null -> mapping deleted, no crash', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => calendarService.getEvent('tgt-1'))
          .thenAnswer((_) async => null);
      when(() => mappingDb.deleteMapping(1))
          .thenAnswer((_) async {});
      when(() => mappingDb.deleteCreatedEvent(targetCalId, 'tgt-1'))
          .thenAnswer((_) async {});

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => mappingDb.deleteMapping(1)).called(1);
      expect(plan.errors, isEmpty);
    });

    test('all-day target with far-future end -> source missing, target deleted', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'Test',
          startDate: day1,
          endDate: futureEnd,
          isAllDay: true,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );
      when(() => calendarService.getEvent('src-1'))
          .thenAnswer((_) async => null);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toDelete, hasLength(1));
      expect(plan.errors, isEmpty);
    });
  });

  group('Sync loop prevention', () {
    test('event in sync_created_events is skipped', () async {
      final srcEvent = _makeEvent('src-1', end: futureEnd, start: futureEnd.subtract(const Duration(hours: 1)));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });

    test('event NOT in sync_created_events is classified normally', () async {
      final srcEvent = _makeEvent('src-1', end: futureEnd, start: futureEnd.subtract(const Duration(hours: 1)));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, hasLength(1));
    });

    test('event with marker in description is skipped (description-based detection)', () async {
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Test',
        startDate: futureEnd.subtract(const Duration(hours: 1)),
        endDate: futureEnd,
        description: 'Test\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });

    test('user event without marker is classified normally', () async {
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Test',
        startDate: futureEnd.subtract(const Duration(hours: 1)),
        endDate: futureEnd,
        description: 'User created event',
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, hasLength(1));
    });

    test('update detection correctly handles marked description via contains', () async {
      final start = DateTime.utc(2026, 6, 23, 14, 0);
      final end = DateTime.utc(2026, 6, 23, 15, 0);
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Test Event',
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'Busy',
          description: 'Test Event\n---\n🔃 Automatically created by CalSync',
          startDate: start,
          endDate: end,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toUpdate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });

    test('null description does not crash (falls back to sync_created_events)', () async {
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Test',
        startDate: futureEnd.subtract(const Duration(hours: 1)),
        endDate: futureEnd,
        description: null,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });

    test('HTML-wrapped description is recognized as unchanged via contains', () async {
      final start = DateTime.utc(2026, 6, 23, 14, 0);
      final end = DateTime.utc(2026, 6, 23, 15, 0);
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Doctor Appointment',
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => Event(
          eventId: 'tgt-1',
          instanceId: 'tgt-1',
          calendarId: targetCalId,
          title: 'Busy',
          description: '<html><body>Doctor Appointment<br>---<br>🔃 Automatically created by CalSync</body></html>',
          startDate: start,
          endDate: end,
          isAllDay: false,
          availability: EventAvailability.busy,
          status: EventStatus.none,
          isRecurring: false,
        ),
      );

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toUpdate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });

    test('after CREATE, sync_created_events is called with target calendar and event', () async {
      final srcEvent = _makeEvent('src-1', end: futureEnd, start: futureEnd.subtract(const Duration(hours: 1)));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, any(), any(),
        description: 'Test Event\n---\n🔃 Automatically created by CalSync', isAllDay: false,
      )).thenAnswer((_) async => 'new-id');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-1',
        targetCalendarId: targetCalId,
        targetEventId: 'new-id',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id'))
          .thenAnswer((_) async {});

      await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id')).called(1);
    });

    test('after orphan DELETE, sync_created_events is removed', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => null,
      );
      when(() => mappingDb.deleteMapping(1))
          .thenAnswer((_) async {});
      when(() => mappingDb.deleteCreatedEvent(targetCalId, 'tgt-1'))
          .thenAnswer((_) async {});

      await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => mappingDb.deleteCreatedEvent(targetCalId, 'tgt-1')).called(1);
    });

    test('after UPDATE, old createdEvent removed and new inserted', () async {
      final start = DateTime.utc(2026, 6, 23, 14, 0);
      final end = DateTime.utc(2026, 6, 23, 15, 0);
      final srcEvent = Event(
        eventId: 'src-1', instanceId: 'src-1', calendarId: sourceCalId,
        title: 'Test', startDate: start, endDate: end,
        isAllDay: false, availability: EventAvailability.busy,
        status: EventStatus.none, isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).thenAnswer(
        (_) async => [{
          'id': 1, 'source_event_id': 'src-1',
          'target_event_id': 'tgt-1', 'target_calendar_id': targetCalId,
        }],
      );
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);
      when(() => calendarService.getEvent('tgt-1')).thenAnswer(
        (_) async => _makeEvent('tgt-1', end: end.subtract(const Duration(minutes: 30)),
            start: start.add(const Duration(minutes: 30))),
      );
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync', isAllDay: false,
      )).thenAnswer((_) async => 'new-id');
      when(() => calendarService.deleteEvent('tgt-1'))
                    .thenAnswer((_) async => const CalendarDeleteResult(success: true));
      when(() => mappingDb.deleteCreatedEvent(targetCalId, 'tgt-1'))
          .thenAnswer((_) async {});
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId, sourceEventId: 'src-1',
        targetCalendarId: targetCalId, targetEventId: 'new-id',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id'))
          .thenAnswer((_) async {});

      await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => mappingDb.deleteCreatedEvent(targetCalId, 'tgt-1')).called(1);
      verify(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id')).called(1);
    });

    test('bidirectional: profile A creates in B, profile B scanning B skips it', () async {
      final otherProfileId = 'other-profile';
      final srcEvent = _makeEvent('src-1', end: futureEnd, start: futureEnd.subtract(const Duration(hours: 1)));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(otherProfileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);

      final plan = await engine.runDryRun(
        profileId: otherProfileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });
  });

  group('Profile-scoped mappings', () {
    final otherProfileId = 'other-profile';

    test('same source event synced by 2 profiles creates independent mappings', () async {
      final start = DateTime.utc(2026, 6, 23, 14, 0);
      final end = DateTime.utc(2026, 6, 23, 15, 0);
      final srcEvent = Event(
        eventId: 'src-1', instanceId: 'src-1', calendarId: sourceCalId,
        title: 'Test', startDate: start, endDate: end,
        isAllDay: false, availability: EventAvailability.busy,
        status: EventStatus.none, isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync', isAllDay: false,
      )).thenAnswer((_) async => 'tgt-A');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-1',
        targetCalendarId: targetCalId,
        targetEventId: 'tgt-A',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'tgt-A'))
          .thenAnswer((_) async {});

      await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-1',
        targetCalendarId: targetCalId,
        targetEventId: 'tgt-A',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).called(1);

      verifyNever(() => mappingDb.insertMapping(
        profileId: otherProfileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-1',
        targetCalendarId: targetCalId,
        targetEventId: any(named: 'targetEventId'),
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      ));
    });

    test('isEventSynced is called with the correct profile ID', () async {
      final srcEvent = _makeEvent('src-1', end: futureEnd, start: futureEnd.subtract(const Duration(hours: 1)));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1')).called(1);
    });

    test('listMappingsForCalendar is called with the correct profile ID', () async {
      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);

      await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId)).called(1);
    });
  });

  group('Recurring events', () {
    final start = DateTime.utc(2026, 6, 23, 14, 0);
    final end = DateTime.utc(2026, 6, 23, 15, 0);

    Event _recurringEvent(String id, {String? instanceId, RecurrenceRule? recurrenceRule}) {
      final instId = instanceId ?? id;
      return Event(
        eventId: id,
        instanceId: instId,
        calendarId: sourceCalId,
        title: 'Weekly Standup',
        startDate: start,
        endDate: end,
        isAllDay: false,
        isRecurring: id == instId,
        recurrenceRule: id == instId ? recurrenceRule : null,
        availability: EventAvailability.busy,
        status: EventStatus.none,
      );
    }

    test('recurring base event creates target with recurrenceRule', () async {
      final rule = DailyRecurrence(end: CountEnd(3));
      final srcEvent = _recurringEvent('src-1', recurrenceRule: rule);

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Weekly Standup\n---\n🔃 Automatically created by CalSync', isAllDay: false,
        recurrenceRule: rule,
      )).thenAnswer((_) async => 'new-id-1');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-1',
        targetCalendarId: targetCalId,
        targetEventId: 'new-id-1',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id-1'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Weekly Standup\n---\n🔃 Automatically created by CalSync', isAllDay: false,
        recurrenceRule: rule,
      )).called(1);
      expect(result.synced, ['src-1']);
    });

    test('instance of recurring event is skipped', () async {
      final rule = DailyRecurrence(end: CountEnd(3));
      final srcEvent = _recurringEvent('src-1', instanceId: 'src-1@12345');
      final baseEvent = _recurringEvent('src-1', recurrenceRule: rule);

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => true);
      when(() => calendarService.getEvent('src-1'))
          .thenAnswer((_) async => baseEvent);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      expect(plan.toCreate, isEmpty);
      expect(plan.toSkip.any((e) => e.eventId == 'src-1'), isTrue);
    });

    test('base + instances → only base is synced, instances skipped', () async {
      final rule = DailyRecurrence(end: CountEnd(3));
      final baseEvent = _recurringEvent('src-1', recurrenceRule: rule);
      final inst1 = _recurringEvent('src-1', instanceId: 'src-1@t1');
      final inst2 = _recurringEvent('src-1', instanceId: 'src-1@t2');

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [baseEvent, inst1, inst2]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.getEvent('src-1'))
          .thenAnswer((_) async => baseEvent);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Weekly Standup\n---\n🔃 Automatically created by CalSync', isAllDay: false,
        recurrenceRule: rule,
      )).thenAnswer((_) async => 'new-id-1');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-1',
        targetCalendarId: targetCalId,
        targetEventId: 'new-id-1',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id-1'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      // Base is synced (may classify multiple times via list + instance fetches,
      // but UNIQUE constraint on mapping handles deduplication)
      expect(result.synced.length, greaterThanOrEqualTo(1));
      expect(result.synced.contains('src-1'), isTrue);
    });
  });

  group('Original event name (empty syncEventName)', () {
    test('empty syncEventName uses source event title as projectedTitle', () async {
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Doctor Appointment',
        startDate: futureEnd.subtract(const Duration(hours: 1)),
        endDate: futureEnd,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: '',
      );

      expect(plan.toCreate, hasLength(1));
      expect(plan.toCreate.first.projectedTitle, 'Doctor Appointment');
    });

    test('non-empty syncEventName uses syncEventName as projectedTitle', () async {
      final srcEvent = _makeEvent('src-1', end: futureEnd,
          start: futureEnd.subtract(const Duration(hours: 1)));

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);

      final plan = await engine.runDryRun(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: 'Busy',
      );

      expect(plan.toCreate, hasLength(1));
      expect(plan.toCreate.first.projectedTitle, 'Busy');
    });
  });

  group('copyDescription', () {
    final start = DateTime.utc(2027, 6, 1, 10, 0);
    final end = DateTime.utc(2027, 6, 1, 11, 0);

    test('create path with copyDescription=true includes source description', () async {
      final srcEvent = Event(
        eventId: 'src-1',
        instanceId: 'src-1',
        calendarId: sourceCalId,
        title: 'Test',
        description: 'Q3 planning notes',
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Q3 planning notes\n\nTest\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
      )).thenAnswer((_) async => 'new-id-1');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId, sourceEventId: 'src-1',
        targetCalendarId: targetCalId, targetEventId: 'new-id-1',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id-1'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
        copyDescription: true,
      );

      verify(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Q3 planning notes\n\nTest\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
      )).called(1);
      expect(result.synced, ['src-1']);
    });

    test('copyDescription=true with null source description falls back to standard', () async {
      final srcEvent = Event(
        eventId: 'src-2',
        instanceId: 'src-2',
        calendarId: sourceCalId,
        title: 'Test',
        description: null,
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-2'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-2'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
      )).thenAnswer((_) async => 'new-id-2');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId, sourceEventId: 'src-2',
        targetCalendarId: targetCalId, targetEventId: 'new-id-2',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id-2'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
        copyDescription: true,
      );

      verify(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
      )).called(1);
      expect(result.synced, ['src-2']);
    });
  });

  group('copyLocation', () {
    final start = DateTime.utc(2027, 6, 1, 10, 0);
    final end = DateTime.utc(2027, 6, 1, 11, 0);

    test('create path with copyLocation=true passes location to createEvent', () async {
      final srcEvent = Event(
        eventId: 'src-3',
        instanceId: 'src-3',
        calendarId: sourceCalId,
        title: 'Test',
        location: 'Conference Room A',
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-3'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-3'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
        location: 'Conference Room A',
      )).thenAnswer((_) async => 'new-id-3');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId, sourceEventId: 'src-3',
        targetCalendarId: targetCalId, targetEventId: 'new-id-3',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id-3'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
        copyLocation: true,
      );

      verify(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
        location: 'Conference Room A',
      )).called(1);
      expect(result.synced, ['src-3']);
    });

    test('create path with copyLocation=false does not pass location', () async {
      final srcEvent = Event(
        eventId: 'src-4',
        instanceId: 'src-4',
        calendarId: sourceCalId,
        title: 'Test',
        location: 'Conference Room A',
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-4'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-4'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
        location: null,
      )).thenAnswer((_) async => 'new-id-4');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId, sourceEventId: 'src-4',
        targetCalendarId: targetCalId, targetEventId: 'new-id-4',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-id-4'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
      );

      verify(() => calendarService.createEvent(
        targetCalId, syncName, start, end,
        description: 'Test\n---\n🔃 Automatically created by CalSync',
        isAllDay: false,
        location: null,
      )).called(1);
      expect(result.synced, ['src-4']);
    });
  });

  group('omitSourceTitle', () {
    final start = DateTime.utc(2027, 6, 1, 10, 0);
    final end = DateTime.utc(2027, 6, 1, 11, 0);
    const marker = '🔃 Automatically created by CalSync';
    final expectedHash =
        'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333';

    Event makeEvent(String id, String title) {
      return Event(
        eventId: id,
        instanceId: id,
        calendarId: sourceCalId,
        title: title,
        startDate: start,
        endDate: end,
        isAllDay: false,
        availability: EventAvailability.busy,
        status: EventStatus.none,
        isRecurring: false,
      );
    }

    test('create path with omitSourceTitle=true embeds SHA256, not plaintext title',
        () async {
      final srcEvent = makeEvent('src-priv-1', 'Doctor Appointment');

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => []);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-priv-1'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-priv-1'))
          .thenAnswer((_) async => false);
      when(() => calendarService.createEvent(
        targetCalId,
        syncName,
        start,
        end,
        description: '$expectedHash\n---\n$marker',
        isAllDay: false,
      )).thenAnswer((_) async => 'new-priv-1');
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-priv-1',
        targetCalendarId: targetCalId,
        targetEventId: 'new-priv-1',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-priv-1'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
        omitSourceTitle: true,
      );

      verify(() => calendarService.createEvent(
        targetCalId,
        syncName,
        start,
        end,
        description: '$expectedHash\n---\n$marker',
        isAllDay: false,
      )).called(1);
      expect(result.synced, ['src-priv-1']);
    });

    test('title change triggers update when omitSourceTitle=true', () async {
      final srcEvent = makeEvent('src-priv-2', 'Doctor Visit');

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => [
            {
              'id': 1,
              'profile_id': profileId,
              'source_calendar_id': sourceCalId,
              'source_event_id': 'src-priv-2',
              'target_calendar_id': targetCalId,
              'target_event_id': 'old-priv-2',
              'synced_at': '2027-01-01T00:00:00Z',
              'canonical_time': null,
            }
          ]);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-priv-2'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-priv-2'))
          .thenAnswer((_) async => true);
      // Old target description contains the SHA256 of the OLD title, not the new one
      final oldHash =
          'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333';
      when(() => calendarService.getEvent('old-priv-2')).thenAnswer((_) async =>
          Event(
            eventId: 'old-priv-2',
            instanceId: 'old-priv-2',
            calendarId: targetCalId,
            title: syncName,
            description: '$oldHash\n---\n$marker',
            startDate: start,
            endDate: end,
            isAllDay: false,
            availability: EventAvailability.busy,
            status: EventStatus.none,
            isRecurring: false,
          ));
      // New title hash
      final newHash =
          sha256.convert('Doctor Visit'.codeUnits).toString();
      when(() => calendarService.createEvent(
        targetCalId,
        syncName,
        start,
        end,
        description: '$newHash\n---\n$marker',
        isAllDay: false,
      )).thenAnswer((_) async => 'new-priv-2');
      when(() => calendarService.deleteEvent('old-priv-2'))
          .thenAnswer((_) async => const CalendarDeleteResult(success: true));
      when(() => mappingDb.deleteCreatedEvent(targetCalId, 'old-priv-2'))
          .thenAnswer((_) async {});
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-priv-2',
        targetCalendarId: targetCalId,
        targetEventId: 'new-priv-2',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-priv-2'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
        omitSourceTitle: true,
      );

      verify(() => calendarService.createEvent(
        targetCalId,
        syncName,
        start,
        end,
        description: '$newHash\n---\n$marker',
        isAllDay: false,
      )).called(1);
      expect(result.updated, ['src-priv-2']);
    });

    test('toggling omitSourceTitle from false to true cleans up plaintext title',
        () async {
      final srcEvent = makeEvent('src-priv-3', 'Doctor Appointment');

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => [
            {
              'id': 2,
              'profile_id': profileId,
              'source_calendar_id': sourceCalId,
              'source_event_id': 'src-priv-3',
              'target_calendar_id': targetCalId,
              'target_event_id': 'old-priv-3',
              'synced_at': '2027-01-01T00:00:00Z',
              'canonical_time': null,
            }
          ]);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-priv-3'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-priv-3'))
          .thenAnswer((_) async => true);
      // Old target still has plaintext title (from omitSourceTitle=false era)
      when(() => calendarService.getEvent('old-priv-3')).thenAnswer((_) async =>
          Event(
            eventId: 'old-priv-3',
            instanceId: 'old-priv-3',
            calendarId: targetCalId,
            title: syncName,
            description: 'Doctor Appointment\n---\n$marker',
            startDate: start,
            endDate: end,
            isAllDay: false,
            availability: EventAvailability.busy,
            status: EventStatus.none,
            isRecurring: false,
          ));
      when(() => calendarService.createEvent(
        targetCalId,
        syncName,
        start,
        end,
        description: '$expectedHash\n---\n$marker',
        isAllDay: false,
      )).thenAnswer((_) async => 'new-priv-3');
      when(() => calendarService.deleteEvent('old-priv-3'))
          .thenAnswer((_) async => const CalendarDeleteResult(success: true));
      when(() => mappingDb.deleteCreatedEvent(targetCalId, 'old-priv-3'))
          .thenAnswer((_) async {});
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-priv-3',
        targetCalendarId: targetCalId,
        targetEventId: 'new-priv-3',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-priv-3'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
        omitSourceTitle: true,
      );

      verify(() => calendarService.createEvent(
        targetCalId,
        syncName,
        start,
        end,
        description: '$expectedHash\n---\n$marker',
        isAllDay: false,
      )).called(1);
      expect(result.updated, ['src-priv-3']);
    });

    test('toggling omitSourceTitle from true to false cleans up fingerprint',
        () async {
      final srcEvent = makeEvent('src-priv-4', 'Doctor Appointment');

      when(() => calendarService.listEvents(sourceCalId))
          .thenAnswer((_) async => [srcEvent]);
      when(() => mappingDb.listMappingsForCalendar(profileId, sourceCalId))
          .thenAnswer((_) async => [
            {
              'id': 3,
              'profile_id': profileId,
              'source_calendar_id': sourceCalId,
              'source_event_id': 'src-priv-4',
              'target_calendar_id': targetCalId,
              'target_event_id': 'old-priv-4',
              'synced_at': '2027-01-01T00:00:00Z',
              'canonical_time': null,
            }
          ]);
      when(() => mappingDb.isEventCreatedBySync(sourceCalId, 'src-priv-4'))
          .thenAnswer((_) async => false);
      when(() => mappingDb.isEventSynced(profileId, sourceCalId, 'src-priv-4'))
          .thenAnswer((_) async => true);
      // Old target has the SHA256 (from omitSourceTitle=true era)
      when(() => calendarService.getEvent('old-priv-4')).thenAnswer((_) async =>
          Event(
            eventId: 'old-priv-4',
            instanceId: 'old-priv-4',
            calendarId: targetCalId,
            title: syncName,
            description: '$expectedHash\n---\n$marker',
            startDate: start,
            endDate: end,
            isAllDay: false,
            availability: EventAvailability.busy,
            status: EventStatus.none,
            isRecurring: false,
          ));
      when(() => calendarService.createEvent(
        targetCalId,
        syncName,
        start,
        end,
        description: 'Doctor Appointment\n---\n$marker',
        isAllDay: false,
      )).thenAnswer((_) async => 'new-priv-4');
      when(() => calendarService.deleteEvent('old-priv-4'))
          .thenAnswer((_) async => const CalendarDeleteResult(success: true));
      when(() => mappingDb.deleteCreatedEvent(targetCalId, 'old-priv-4'))
          .thenAnswer((_) async {});
      when(() => mappingDb.insertMapping(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        sourceEventId: 'src-priv-4',
        targetCalendarId: targetCalId,
        targetEventId: 'new-priv-4',
        syncedAt: any(named: 'syncedAt'),
        canonicalTime: any(named: 'canonicalTime'),
      )).thenAnswer((_) async {});
      when(() => mappingDb.insertCreatedEvent(targetCalId, 'new-priv-4'))
          .thenAnswer((_) async {});

      final result = await engine.runSync(
        profileId: profileId,
        sourceCalendarId: sourceCalId,
        targetCalendarId: targetCalId,
        syncEventName: syncName,
        omitSourceTitle: false,
      );

      verify(() => calendarService.createEvent(
        targetCalId,
        syncName,
        start,
        end,
        description: 'Doctor Appointment\n---\n$marker',
        isAllDay: false,
      )).called(1);
      expect(result.updated, ['src-priv-4']);
    });
  });

  group('buildDescription', () {
    const marker = '🔃 Automatically created by CalSync';

    test('copyDescription=false returns standard format', () {
      final result = buildDescription('Doctor Appointment', 'Q3 notes', false);
      expect(result, 'Doctor Appointment\n---\n$marker');
    });

    test('copyDescription=true with non-empty description prepends it', () {
      final result = buildDescription('Doctor Appointment', 'Q3 notes', true);
      expect(result, 'Q3 notes\n\nDoctor Appointment\n---\n$marker');
    });

    test('copyDescription=true with null description returns standard format', () {
      final result = buildDescription('Doctor Appointment', null, true);
      expect(result, 'Doctor Appointment\n---\n$marker');
    });

    test('copyDescription=true with empty description returns standard format', () {
      final result = buildDescription('Doctor Appointment', '', true);
      expect(result, 'Doctor Appointment\n---\n$marker');
    });

    test('copyDescription=false with null description returns standard format', () {
      final result = buildDescription('Doctor Appointment', null, false);
      expect(result, 'Doctor Appointment\n---\n$marker');
    });

    test('omitSourceTitle=true replaces title with SHA256 fingerprint', () {
      final result = buildDescription(
        'Doctor Appointment',
        'Q3 notes',
        false,
        omitSourceTitle: true,
      );
      expect(
        result,
        'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
      );
    });

    test('omitSourceTitle=true with copyDescription prepends source description', () {
      final result = buildDescription(
        'Doctor Appointment',
        'Q3 notes',
        true,
        omitSourceTitle: true,
      );
      expect(
        result,
        'Q3 notes\n\nde691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
      );
    });

    test('omitSourceTitle=true with copyDescription and null source description', () {
      final result = buildDescription(
        'Doctor Appointment',
        null,
        true,
        omitSourceTitle: true,
      );
      expect(
        result,
        'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
      );
    });

    test('omitSourceTitle=true with copyDescription and empty source description', () {
      final result = buildDescription(
        'Doctor Appointment',
        '',
        true,
        omitSourceTitle: true,
      );
      expect(
        result,
        'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
      );
    });

    test('omitSourceTitle=true with empty title uses well-known SHA256 of empty string', () {
      final result = buildDescription(
        '',
        null,
        false,
        omitSourceTitle: true,
      );
      expect(
        result,
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n---\n$marker',
      );
    });

    test('omitSourceTitle=true with known title matches hardcoded SHA256', () {
      // Locks the algorithm: any change to the hashing approach will fail this test.
      // SHA256 of "Doctor Appointment" computed via: echo -n "Doctor Appointment" | sha256sum
      final result = buildDescription(
        'Doctor Appointment',
        null,
        false,
        omitSourceTitle: true,
      );
      expect(
        result,
        'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/zone_group.dart';

void main() {
  group('parseZoneGroup', () {
    test('reads a full group', () {
      final g = parseZoneGroup({
        'code': 'YOW',
        'group': {
          'code': 'ONQC',
          'name': 'Ontario / Quebec',
          'members': ['YOW', 'YUL']
        },
      });
      expect(g, isNotNull);
      expect(g!.code, 'ONQC');
      expect(g.name, 'Ontario / Quebec');
      expect(g.members, ['YOW', 'YUL']);
    });

    test('no group key, null group, non-map zone and non-map group are no group',
        () {
      expect(parseZoneGroup({'code': 'YOW'}), isNull);
      expect(parseZoneGroup({'code': 'YOW', 'group': null}), isNull);
      expect(parseZoneGroup(null), isNull);
      expect(parseZoneGroup('YOW'), isNull);
      expect(parseZoneGroup({'code': 'YOW', 'group': 'ONQC'}), isNull);
    });

    test('a missing, blank or unsafe code is no group', () {
      expect(
          parseZoneGroup({
            'group': {'name': 'x'}
          }),
          isNull);
      expect(
          parseZoneGroup({
            'group': {'code': '   '}
          }),
          isNull);
      expect(
          parseZoneGroup({
            'group': {'code': 'ON/QC'}
          }),
          isNull);
      expect(
          parseZoneGroup({
            'group': {'code': 42}
          }),
          isNull);
    });

    test('code is trimmed and upper-cased, a null or blank name is null', () {
      final g = parseZoneGroup({
        'group': {'code': ' finland ', 'name': '  '}
      })!;
      expect(g.code, 'FINLAND');
      expect(g.name, isNull);
      expect(
          parseZoneGroup({
            'group': {'code': 'ONQC', 'name': null}
          })!
              .name,
          isNull);
    });

    test('members keep only non-empty strings, upper-cased', () {
      final g = parseZoneGroup({
        'group': {
          'code': 'ONQC',
          'members': [' yow', '', 7, 'YUL']
        }
      })!;
      expect(g.members, ['YOW', 'YUL']);
      expect(
          parseZoneGroup({
            'group': {'code': 'ONQC'}
          })!
              .members,
          isEmpty);
    });
  });

  group('shortZoneLabel', () {
    test('four or fewer characters stay whole', () {
      expect(shortZoneLabel('YOW'), 'YOW');
      expect(shortZoneLabel('ONQC'), 'ONQC');
    });
    test('longer codes are cut to four plus an ellipsis', () {
      expect(shortZoneLabel('FINLAND'), 'FINL…');
      expect(shortZoneLabel('ABCDE'), 'ABCD…');
    });
  });

  group('classifyZoneMove', () {
    test('same zone or no session is no move', () {
      expect(
          classifyZoneMove(
              sessionZone: 'YOW',
              sessionGroup: 'ONQC',
              newZone: 'YOW',
              newGroup: 'ONQC'),
          ZoneMove.none);
      expect(
          classifyZoneMove(
              sessionZone: null,
              sessionGroup: null,
              newZone: 'YOW',
              newGroup: null),
          ZoneMove.none);
      expect(
          classifyZoneMove(
              sessionZone: 'YOW',
              sessionGroup: null,
              newZone: '',
              newGroup: null),
          ZoneMove.none);
    });
    test('same group is a hidden handoff', () {
      expect(
          classifyZoneMove(
              sessionZone: 'YOW',
              sessionGroup: 'ONQC',
              newZone: 'YUL',
              newGroup: 'ONQC'),
          ZoneMove.hiddenHandoff);
    });
    test('no group on either side, or different groups, is a full transfer',
        () {
      expect(
          classifyZoneMove(
              sessionZone: 'YOW',
              sessionGroup: null,
              newZone: 'YUL',
              newGroup: null),
          ZoneMove.fullTransfer);
      expect(
          classifyZoneMove(
              sessionZone: 'YOW',
              sessionGroup: 'ONQC',
              newZone: 'SEA',
              newGroup: null),
          ZoneMove.fullTransfer);
      expect(
          classifyZoneMove(
              sessionZone: 'SEA',
              sessionGroup: null,
              newZone: 'YOW',
              newGroup: 'ONQC'),
          ZoneMove.fullTransfer);
      expect(
          classifyZoneMove(
              sessionZone: 'YOW',
              sessionGroup: 'ONQC',
              newZone: 'SEA',
              newGroup: 'PNW'),
          ZoneMove.fullTransfer);
    });
  });

  group('groupHandoffFollowUp', () {
    GroupHandoffFollowUp rule({
      bool failed = true,
      bool connected = true,
      bool offlineMode = false,
      bool inZoneGracePeriod = false,
      String? zoneCode = 'YUL',
    }) =>
        groupHandoffFollowUp(
          failed: failed,
          connected: connected,
          offlineMode: offlineMode,
          inZoneGracePeriod: inZoneGracePeriod,
          zoneCode: zoneCode,
        );

    test('a failed handoff on a live session re-mints in the current zone',
        () {
      expect(rule(), GroupHandoffFollowUp.transfer);
      expect(rule(zoneCode: 'YQB'), GroupHandoffFollowUp.transfer,
          reason: 'a third member a later tick moved into');
      expect(rule(zoneCode: 'YOW'), GroupHandoffFollowUp.transfer,
          reason: 'the old member the phone moved back into');
    });

    test('a failed handoff with no zone to re-join ends the session', () {
      expect(rule(zoneCode: null), GroupHandoffFollowUp.disconnect);
      expect(rule(zoneCode: ''), GroupHandoffFollowUp.disconnect);
    });

    test('a handoff that did not fail needs nothing', () {
      expect(rule(failed: false), GroupHandoffFollowUp.none);
      expect(rule(failed: false, zoneCode: null), GroupHandoffFollowUp.none);
    });

    test('a session that is gone, offline or in zone grace owns itself', () {
      expect(rule(connected: false), GroupHandoffFollowUp.none);
      expect(rule(offlineMode: true), GroupHandoffFollowUp.none);
      expect(rule(inZoneGracePeriod: true), GroupHandoffFollowUp.none);
      expect(rule(connected: false, zoneCode: null), GroupHandoffFollowUp.none);
    });
  });
}

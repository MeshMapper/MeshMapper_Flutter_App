import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';

/// The site details an administrator fills in about their installation, plus
/// the preset the repeater is currently heard on. Every field is additive and
/// absent on most repeaters (24 to 58 of 404 in a real YOW fetch) and on any
/// server that predates them, so absent is the expected state, not an error.
void main() {
  final base = {
    'id': 'CBC001',
    'hex_id': 'ab' * 32,
    'name': 'CBC-FORTUNE-R1',
    'lat': 45.50256,
    'lon': -75.84988,
    'last_heard': 0,
    'enabled': 1,
  };

  group('parsing', () {
    test('an old list has none of the fields', () {
      final r = Repeater.fromJson(base);
      expect(r.hardware, isNull);
      expect(r.antenna, isNull);
      expect(r.heightMeters, isNull);
      expect(r.power, isNull);
      expect(r.powerSource, isNull);
      expect(r.siteNotes, isNull);
      expect(r.presetCurrent, isNull);
    });

    test('CBC001 as the server really sends it', () {
      final r = Repeater.fromJson({
        ...base,
        'hardware': 'Station G3',
        'antenna': 'Seeed 8dBi',
        'height_m': 15,
        'power': '1.0W',
        'power_source': 'poe',
        'site_notes': 'The system is mounted atop a grain silo',
        'preset_current': '910.525,62.5,7',
      });
      expect(r.hardware, 'Station G3');
      expect(r.antenna, 'Seeed 8dBi');
      expect(r.heightMeters, 15.0);
      expect(r.power, '1.0W');
      expect(r.powerSource, 'poe');
      expect(r.siteNotes, 'The system is mounted atop a grain silo');
      expect(r.presetCurrent, '910.525,62.5,7');
    });

    test('height arrives as int, double or a numeric string', () {
      double? h(Object? raw) =>
          Repeater.fromJson({...base, 'height_m': raw}).heightMeters;
      expect(h(40), 40.0);
      expect(h(22.9), 22.9);
      expect(h('6.4'), 6.4);
      expect(h('tall'), isNull);
      expect(h(null), isNull);
    });

    test('a blank string is the same as absent', () {
      final r = Repeater.fromJson({
        ...base,
        'hardware': '',
        'antenna': '   ',
        'site_notes': '',
      });
      expect(r.hardware, isNull);
      expect(r.antenna, isNull);
      expect(r.siteNotes, isNull);
    });

    test('strings are trimmed', () {
      final r = Repeater.fromJson({...base, 'hardware': '  Heltec V3 '});
      expect(r.hardware, 'Heltec V3');
    });

    test('a non-string value is ignored rather than stringified', () {
      final r = Repeater.fromJson({...base, 'hardware': 7, 'antenna': true});
      expect(r.hardware, isNull);
      expect(r.antenna, isNull);
    });

    test('set fields round-trip through toJson, absent ones stay absent', () {
      final full = Repeater.fromJson({
        ...base,
        'hardware': 'Ikoka',
        'height_m': 10,
        'power_source': 'solar',
      });
      final json = full.toJson();
      expect(json['hardware'], 'Ikoka');
      expect(json['height_m'], 10.0);
      expect(json['power_source'], 'solar');
      expect(json.containsKey('antenna'), isFalse);
      expect(json.containsKey('site_notes'), isFalse);
      expect(Repeater.fromJson(base).toJson().containsKey('hardware'), isFalse);
    });
  });

  group('displayPower', () {
    // The column is hand-typed, so every one of these is a real stored value.
    test('a bare number gains its unit', () {
      expect(_power('0.3'), '0.3W');
      expect(_power('1.0'), '1.0W');
      expect(_power('0.6'), '0.6W');
    });

    test('a lower-case unit is normalised', () {
      expect(_power('0.3w'), '0.3W');
    });

    test('an already-correct value is left alone', () {
      expect(_power('1.0W'), '1.0W');
      expect(_power('0.2W'), '0.2W');
    });

    test('anything unrecognised is shown as typed', () {
      expect(_power('half a watt'), 'half a watt');
      expect(_power('  2.5 W  '), '2.5 W');
    });

    test('absent stays absent', () {
      expect(_power(null), isNull);
    });
  });

  group('displayPowerSource', () {
    test('the three known sources get their proper casing', () {
      expect(_source('solar'), 'Solar');
      expect(_source('poe'), 'PoE');
      expect(_source('mains'), 'Mains');
    });

    test('casing in the stored value does not matter', () {
      expect(_source('PoE'), 'PoE');
      expect(_source('SOLAR'), 'Solar');
    });

    test('an unknown source is capitalised, not dropped', () {
      expect(_source('battery'), 'Battery');
    });

    test('absent stays absent', () {
      expect(_source(null), isNull);
    });
  });

  group('displayPreset', () {
    test('the tag becomes readable radio settings', () {
      expect(_preset('910.525,62.5,7'), '910.525 MHz · 62.5 kHz · SF7');
      expect(_preset('869.525,250,11'), '869.525 MHz · 250 kHz · SF11');
    });

    test('surrounding whitespace in a slot is tolerated', () {
      expect(_preset(' 910.525 , 62.5 , 7 '), '910.525 MHz · 62.5 kHz · SF7');
    });

    test('a tag that is not three numeric slots is shown as stored', () {
      expect(_preset('910.525,62.5'), '910.525,62.5');
      expect(_preset('910.525,62.5,7,5'), '910.525,62.5,7,5');
      expect(_preset('wideband'), 'wideband');
      expect(_preset('910.525,wide,7'), '910.525,wide,7');
    });

    test('absent stays absent', () {
      expect(_preset(null), isNull);
    });
  });
}

Repeater _with(String key, Object? value) => Repeater.fromJson({
      'id': 'X',
      'hex_id': 'ab' * 32,
      'name': 'R',
      'lat': 1.0,
      'lon': 2.0,
      'last_heard': 0,
      'enabled': 1,
      if (value != null) key: value,
    });

String? _power(String? raw) => _with('power', raw).displayPower;
String? _source(String? raw) => _with('power_source', raw).displayPowerSource;
String? _preset(String? raw) => _with('preset_current', raw).displayPreset;

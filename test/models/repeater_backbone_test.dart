import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';

/// The backbone fields are added lazily server-side, so the ABSENT case is the
/// normal one and has to behave exactly like "not backbone" with nothing
/// logged and nothing surfaced. Both paths are covered here against a faked
/// response, because the app ships ahead of the server half.
void main() {
  final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Map<String, dynamic> base({int? staleTime, int? createdAt}) => {
        'id': '4E',
        'hex_id': 'ab' * 32,
        'name': 'Hill',
        'lat': 1.0,
        'lon': 2.0,
        'last_heard': nowSeconds,
        'enabled': 1,
        'stale_time': staleTime ?? nowSeconds + 3600,
        if (createdAt != null) 'created_at': createdAt,
      };

  group('absent is the normal case', () {
    test('a response with no backbone key is simply not backbone', () {
      final r = Repeater.fromJson(base());
      expect(r.backbone, isFalse);
      expect(r.backboneShare, isNull);
      expect(r.isBackbone, isFalse);
    });

    test('an absent key round-trips as absent, not as a false', () {
      final json = Repeater.fromJson(base()).toJson();
      expect(json.containsKey('backbone'), isFalse);
      expect(json.containsKey('backbone_share'), isFalse);
    });
  });

  group('a server that sends the fields', () {
    test('backbone: 1 marks an active repeater', () {
      final r = Repeater.fromJson({...base(), 'backbone': 1});
      expect(r.backbone, isTrue);
      expect(r.isBackbone, isTrue);
    });

    test('backbone: 0 is not backbone', () {
      final r = Repeater.fromJson({...base(), 'backbone': 0});
      expect(r.backbone, isFalse);
      expect(r.isBackbone, isFalse);
    });

    test('true and "1" are accepted, since the field crosses PHP', () {
      expect(Repeater.fromJson({...base(), 'backbone': true}).backbone, isTrue);
      expect(Repeater.fromJson({...base(), 'backbone': '1'}).backbone, isTrue);
    });

    test('backbone_share parses a float and a numeric string', () {
      expect(Repeater.fromJson({...base(), 'backbone_share': 0.125}).backboneShare,
          0.125);
      expect(
          Repeater.fromJson({...base(), 'backbone_share': '0.25'}).backboneShare,
          0.25);
    });

    test('a junk or non-finite share is dropped, not crashed on', () {
      for (final value in [
        'not a number',
        double.nan,
        double.infinity,
        true,
        <String>[],
      ]) {
        expect(
          () => Repeater.fromJson({...base(), 'backbone_share': value}),
          returnsNormally,
          reason: 'share $value',
        );
        expect(
          Repeater.fromJson({...base(), 'backbone_share': value}).backboneShare,
          isNull,
          reason: 'share $value',
        );
      }
    });

    test('a set backbone round-trips', () {
      final json =
          Repeater.fromJson({...base(), 'backbone': 1, 'backbone_share': 0.3})
              .toJson();
      final again = Repeater.fromJson({...base(), ...json});
      expect(again.backbone, isTrue);
      expect(again.backboneShare, 0.3);
    });
  });

  group('backbone never stacks with another state', () {
    test('a stale repeater the server marked keeps its own state', () {
      final stale = Repeater.fromJson({
        ...base(staleTime: nowSeconds - 3600),
        'last_heard': nowSeconds - 3600,
        'backbone': 1,
      });
      expect(stale.backbone, isTrue, reason: 'the raw field is still carried');
      expect(stale.isActive, isFalse);
      expect(stale.isBackbone, isFalse,
          reason: 'only an active repeater is ever drawn as backbone');
    });
  });
}

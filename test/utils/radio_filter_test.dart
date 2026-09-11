// test/utils/radio_filter_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/radio_filter.dart';

/// The filter the app sends to the region doors is the first three slots of
/// the radio tag as separate parameters, never the coding rate. Anything the
/// radio did not report makes the whole filter null, so the reads go out
/// unfiltered (fail open) rather than with a slot the server cannot match.
void main() {
  group('radioFilterFromTag', () {
    test('splits the tag into freq, bw and sf and drops the coding rate', () {
      expect(radioFilterFromTag('910.525,62.5,7,5'),
          {'f_freq': '910.525', 'f_bw': '62.5', 'f_sf': '7'});
    });

    test('keeps the values exactly as the tag carries them', () {
      // 915 (no decimals) and 250 pass through untouched: the server matches
      // the slot as the app reported it, so no reformatting here.
      expect(radioFilterFromTag('915,250,10,5'),
          {'f_freq': '915', 'f_bw': '250', 'f_sf': '10'});
    });

    test('null and empty tags give no filter', () {
      expect(radioFilterFromTag(null), isNull);
      expect(radioFilterFromTag(''), isNull);
    });

    test('a tag with fewer than four slots gives no filter', () {
      expect(radioFilterFromTag('910.525,62.5'), isNull);
    });

    test('an unknown spreading factor (0) gives no filter', () {
      // SelfInfo writes 0 for a missing SF; f_sf=0 would match nothing.
      expect(radioFilterFromTag('910.525,62.5,0,5'), isNull);
    });

    test('an unknown bandwidth (0) gives no filter', () {
      expect(radioFilterFromTag('910.525,0,7,5'), isNull);
    });
  });

  group('radioFilterKey', () {
    test('joins the three slots for cache comparison', () {
      expect(radioFilterKey({'f_freq': '910.525', 'f_bw': '62.5', 'f_sf': '7'}),
          '910.525,62.5,7');
    });

    test('null filter gives null key', () {
      expect(radioFilterKey(null), isNull);
    });
  });
}

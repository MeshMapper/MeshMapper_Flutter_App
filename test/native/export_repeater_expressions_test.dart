import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/repeater_marker_style.dart';

// Used by the native simulator regression check to exercise production JSON.
void main() {
  const output = String.fromEnvironment('REPEATER_EXPRESSIONS_OUTPUT');
  test('export the cluster image expressions for the native regression check', () {
    File(output).writeAsStringSync(jsonEncode({
      'badge': RepeaterMarkerStyle.dominantStatusExpression(
        (status) => 'badge_${status.wireKey}',
      ),
      'dots': RepeaterMarkerStyle.presenceMaskImageExpression(
        (mask) => 'dots$mask',
      ),
    }));
  }, skip: output.isEmpty ? 'Run through the native simulator check' : false);
}

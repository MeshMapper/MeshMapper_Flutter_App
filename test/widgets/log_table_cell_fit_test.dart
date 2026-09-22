import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/widgets/log_table_cell_fit.dart';
import 'package:mesh_mapper/widgets/repeater_id_chip.dart';

void main() {
  testWidgets('keeps enlarged table content inside its assigned cell',
      (tester) async {
    const nodeCellKey = Key('node-cell');
    const nodeContentKey = Key('node-content');
    const metricCellKey = Key('metric-cell');
    const metricContentKey = Key('metric-content');

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(3),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(
                key: nodeCellKey,
                width: 92,
                child: LogTableCellFit(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    key: nodeContentKey,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RepeaterIdChip(
                        repeaterId: '151515',
                        fontSize: 14,
                      ),
                      Text('(RM)', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ),
              SizedBox(
                key: metricCellKey,
                width: 52,
                child: LogTableCellFit(
                  child: Container(
                    key: metricContentKey,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: const Text(
                      '-20.0',
                      style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    _expectContained(tester, nodeCellKey, nodeContentKey);
    _expectContained(tester, metricCellKey, metricContentKey);
  });
}

void _expectContained(WidgetTester tester, Key cellKey, Key contentKey) {
  final cell = tester.getRect(find.byKey(cellKey));
  final content = tester.getRect(find.byKey(contentKey));

  expect(content.left, greaterThanOrEqualTo(cell.left));
  expect(content.top, greaterThanOrEqualTo(cell.top));
  expect(content.right, lessThanOrEqualTo(cell.right));
  expect(content.bottom, lessThanOrEqualTo(cell.bottom));
}

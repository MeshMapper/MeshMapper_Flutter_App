import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/widgets/upload_logs_dialog.dart';

/// Users kept submitting debug logs with notes like "mapped this area",
/// expecting the upload to be how their coverage reaches MeshMapper. It never
/// was: pings upload on their own, and an Offline Mode session uploads from
/// Settings > Data. So the log upload now opens with a dialog that says what
/// this does and what it does not, and Cancel there must stop the flow before
/// the upload sheet (and its file pickers) ever appear.
///
/// The confirmation reads nothing from the provider, so the stand-in here
/// throws on every member: building a real [AppStateProvider] starts the whole
/// app (GPS, audio, portal, Hive), and a reach for any of it is a bug this
/// test should catch rather than quietly satisfy.
class _UntouchableAppState implements AppStateProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'the confirmation reached for ${invocation.memberName}');
}

void main() {
  /// Taps the entry point and settles on whatever the first surface is.
  Future<List<UploadLogsResult?>> openUpload(WidgetTester tester) async {
    final results = <UploadLogsResult?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              results.add(
                await showUploadLogsDialog(context, _UntouchableAppState()),
              );
            },
            child: const Text('Upload'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('the upload opens with the purpose confirmation, not the sheet',
      (tester) async {
    await openUpload(tester);

    expect(find.text('Upload debug logs?'), findsOneWidget);

    // The three things a confused user needs to read, in the dialog itself.
    expect(
      find.textContaining('only for troubleshooting the app'),
      findsOneWidget,
      reason: 'the dialog must say what the upload is for',
    );
    expect(
      find.textContaining('does not upload the areas you mapped'),
      findsOneWidget,
      reason: 'this is the misunderstanding the dialog exists to correct',
    );
    expect(
      find.textContaining('Offline Mode'),
      findsOneWidget,
      reason: 'offline users must be pointed at the right screen',
    );
    expect(find.textContaining('Settings > Data'), findsOneWidget);
  });

  testWidgets('Cancel stops before the upload sheet and reports no result',
      (tester) async {
    final results = await openUpload(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Upload debug logs?'), findsNothing);
    // Null is what the caller reads as "nothing happened", so it shows no
    // success toast and no error toast.
    expect(results, [null]);
  });

  testWidgets('Continue dismisses the confirmation and goes on to the sheet',
      (tester) async {
    await openUpload(tester);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Upload debug logs?'), findsNothing);
    // Continuing hands off to the real upload sheet, which is the surface
    // that was there before this gate existed.
    expect(find.byType(UploadLogsSheet), findsOneWidget);
  });
}

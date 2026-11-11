import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/store_links.dart';
import 'package:mesh_mapper/widgets/update_required_panel.dart';

void main() {
  testWidgets('shows the versions and opens the Play link', (tester) async {
    // The installer source the provider would have read on a Play install.
    final link =
        StoreLinks.resolve(TargetPlatform.android, 'com.android.vending');
    StoreLink? opened;
    var backTapped = false;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UpdateRequiredPanel(
          requirement: AppUpdateRequirement(
            errorMessage: 'out of date',
            versionLine: appUpdateVersionLine('APP-1.3.0', '1.4.0'),
            link: link,
          ),
          onUpdate: (l) => opened = l,
          onBack: () => backTapped = true,
        ),
      ),
    ));

    expect(find.text(UpdateRequiredPanel.title), findsOneWidget);
    expect(find.text(UpdateRequiredPanel.body), findsOneWidget);
    expect(find.text('Your version: 1.3.0 · Needed: 1.4.0'), findsOneWidget);

    await tester.tap(find.text('Update MeshMapper'));
    expect(opened, StoreLinks.playStore);

    await tester.tap(find.text('Back'));
    expect(backTapped, isTrue);
  });

  testWidgets('a sideloaded APK offers the release download', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UpdateRequiredPanel(
          requirement: AppUpdateRequirement(
            errorMessage: 'out of date',
            versionLine: appUpdateVersionLine('APP-1.3.0', null),
            link: StoreLinks.resolve(TargetPlatform.android, null),
          ),
          onUpdate: (_) {},
          onBack: () {},
        ),
      ),
    ));

    expect(find.text('Download latest version'), findsOneWidget);
    expect(find.text('Your version: 1.3.0'), findsOneWidget);
  });
}

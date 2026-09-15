import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../utils/ping_colors.dart';
import '../../widgets/background_location_setup.dart';
import '../../widgets/carpeater_setup_dialog.dart';

List<Widget> buildOnboardingGuidePages(BuildContext context) => [
      buildConnectPage(context),
      buildAntennaPage(context),
      buildModesPage(context),
      buildMapControlsPage(context),
      buildSmartPingingPage(context),
      buildCarpeaterPage(context),
      buildBackgroundPage(context),
      buildResultsPage(context),
      buildOnlineOfflinePage(context),
      buildPrivacyPage(context),
      buildAccountPage(context),
      buildAutomaticUploadsPage(context),
    ];

class OnboardingGuidePage extends StatelessWidget {
  const OnboardingGuidePage({
    required this.title,
    required this.accent,
    required this.children,
    super.key,
  });

  final String title;
  final Color accent;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 44,
                height: 5,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
              ),
              const SizedBox(height: 18),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class GuideParagraph extends StatelessWidget {
  const GuideParagraph(this.text, {this.emphasis = false, super.key});

  final String text;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              height: 1.45,
              fontWeight: emphasis ? FontWeight.w600 : null,
            ),
      ),
    );
  }
}

class GuideSectionLabel extends StatelessWidget {
  const GuideSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class GuideBullet extends StatelessWidget {
  const GuideBullet(this.text, {this.icon = Icons.check_circle, super.key});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: colors.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class GuideCallout extends StatelessWidget {
  const GuideCallout({
    required this.text,
    this.icon = Icons.info_outline,
    this.color,
    super.key,
  });

  final String text;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        border: Border(left: BorderSide(color: accent, width: 4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class GuideComparison extends StatelessWidget {
  const GuideComparison({
    required this.left,
    required this.right,
    super.key,
  });

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 430) {
            return Column(children: [left, const SizedBox(height: 10), right]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 10),
              Expanded(child: right),
            ],
          );
        },
      ),
    );
  }
}

class GuideIconRow extends StatelessWidget {
  const GuideIconRow({
    required this.icon,
    required this.title,
    required this.text,
    this.color,
    super.key,
  });

  final IconData icon;
  final String title;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = color ?? colors.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accent, semanticLabel: title),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
                const SizedBox(height: 2),
                Text(text,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          height: 1.35,
                        )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VisualPanel extends StatelessWidget {
  const _VisualPanel({
    required this.child,
    required this.label,
    this.color,
  });

  final Widget child;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = color ?? colors.primary;
    return Semantics(
      label: label,
      image: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
          border: Border.all(color: accent.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: ExcludeSemantics(child: child),
      ),
    );
  }
}

class _CompactCard extends StatelessWidget {
  const _CompactCard({
    required this.title,
    required this.child,
    required this.icon,
    required this.color,
  });

  final String title;
  final Widget child;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
              ),
            ],
          ),
          const SizedBox(height: 9),
          child,
        ],
      ),
    );
  }
}

Widget buildConnectPage(BuildContext context) {
  const accent = Color(0xFF2E7D32);
  return const OnboardingGuidePage(
    title: 'Connect Your MeshCore Radio',
    accent: accent,
    children: [
      GuideParagraph(
        'Open the Connect tab and choose how your radio is connected. Bluetooth is the usual choice. TCP and USB may also be available on supported devices.',
      ),
      _VisualPanel(
        label: 'Disconnected Connection screen with remembered radio controls',
        color: accent,
        child: _DisconnectedConnectionPreview(),
      ),
      _VisualPanel(
        label: 'Connected Connection screen with radio details',
        color: accent,
        child: _ConnectedConnectionPreview(),
      ),
      GuideIconRow(
          icon: Icons.radar, title: '1. Tap Scan', text: 'Find nearby radios.'),
      GuideIconRow(
        icon: Icons.memory,
        title: '2. Select your MeshCore companion',
        text: 'Choose the radio you want to map with.',
      ),
      GuideIconRow(
        icon: Icons.check_circle_outline,
        title: '3. Wait for Connected',
        text: 'The setup steps finish before wardriving controls are enabled.',
        color: accent,
      ),
      GuideCallout(
        text:
            'MeshMapper checks your GPS location, signs into your regional zone, prepares the wardriving channel, and detects your radio model. A previously connected radio will be remembered for quicker reconnection.',
        icon: Icons.sync,
        color: accent,
      ),
      GuideCallout(
        text:
            "MeshMapper detects and reports the radio's expected power. It never changes the radio's actual transmit power.",
        icon: Icons.power_settings_new,
        color: Colors.orange,
      ),
    ],
  );
}

Widget buildAntennaPage(BuildContext context) {
  const accent = Color(0xFF00796B);
  return const OnboardingGuidePage(
    title: 'Is Your Antenna Exposed?',
    accent: accent,
    children: [
      GuideParagraph(
        'Set the required External Antenna: Yes / No control on the Map screen for the setup used on that drive.',
      ),
      GuideComparison(
        left: _CompactCard(
          title: 'Choose No',
          icon: Icons.directions_car,
          color: Colors.blueGrey,
          child: Column(
            children: [
              Icon(Icons.wifi_tethering_off, size: 44),
              SizedBox(height: 8),
              Text(
                'The antenna is inside a metal vehicle cabin, metal box, or another enclosure that can reduce RF reception. Example: the radio and antenna are inside the car.',
              ),
            ],
          ),
        ),
        right: _CompactCard(
          title: 'Choose Yes',
          icon: Icons.cell_tower,
          color: accent,
          child: Column(
            children: [
              Icon(Icons.wifi_tethering, size: 44),
              SizedBox(height: 8),
              Text(
                'The antenna is not enclosed by metal or another object that significantly blocks RF reception. Examples: a roof-mounted antenna, a handheld radio, or walking with the radio in a pocket.',
              ),
            ],
          ),
        ),
      ),
      GuideCallout(
        text:
            'This does not change your radio or its transmit power. It records how the antenna was positioned so the community can interpret the coverage data correctly.',
        icon: Icons.analytics_outlined,
        color: accent,
      ),
      GuideCallout(
        text: 'Choose Yes or No on the Map screen before starting a mode.',
        icon: Icons.touch_app,
        color: accent,
      ),
    ],
  );
}

Widget buildModesPage(BuildContext context) {
  const accent = Color(0xFF00A7A7);
  return OnboardingGuidePage(
    title: 'Wardriving Modes',
    accent: accent,
    children: [
      const GuideIconRow(
        icon: Icons.hearing,
        title: 'Passive Mode',
        text:
            'Sends a zero-hop discovery request to every repeater that can hear you, and each repeater replies directly. It also continuously listens for received mesh traffic. This provides the best balance of broad mesh coverage and low airtime use.',
        color: accent,
      ),
      const GuideIconRow(
        icon: Icons.gps_fixed,
        title: 'Trace Mode',
        text:
            'Sends a zero-hop trace to one specific repeater. Only that repeater responds. It uses the least airtime but focuses on a single repeater, making it useful for antenna alignment or checking a specific node.',
        color: Colors.cyan,
      ),
      const GuideIconRow(
        icon: Icons.compare_arrows,
        title: 'Hybrid Mode',
        text:
            'Alternates between zero-hop discovery requests and channel flood messages that propagate through the mesh. The flood messages use more airtime than a zero-hop discovery request.',
        color: Colors.purple,
      ),
      GuideIconRow(
        icon: Icons.sensors,
        title: 'Active Mode',
        text:
            'Active Mode uses the most airtime on the mesh. It only sends channel flood messages that propagate through the mesh. It is the most aggressive mode and provides more detailed mapping at the cost of higher airtime utilization.',
        color: PingColors.txSuccess,
      ),
      const GuideCallout(
        text:
            'Active Mode is disabled by default in MeshMapper. Regional administrators may disable flood traffic, which hides Hybrid and Active modes, to preserve airtime and reduce the load MeshMapper places on the mesh.',
        icon: Icons.public,
        color: accent,
      ),
      const GuideCallout(
        text:
            'MeshMapper requires at least 25 metres of movement between automatic attempts. If you see Move 25 m, continue travelling and the session will resume automatically.',
        icon: Icons.straighten,
        color: Colors.orange,
      ),
      const GuideIconRow(
        icon: Icons.touch_app,
        title: 'Start and stop',
        text:
            'Tap a mode to start it and tap the running mode again to stop. Wait for Stopping to finish before disconnecting. Status text explains when the app is waiting for GPS, movement, or cooldown.',
        color: accent,
      ),
      const GuideCallout(
        text:
            'Use the ? button on the wardriving control panel to reopen help for the antenna and mode buttons.',
        icon: Icons.help_outline,
        color: accent,
      ),
    ],
  );
}

Widget buildMapControlsPage(BuildContext context) {
  const accent = Color(0xFF1565C0);
  const controls = <(IconData, String, String)>[
    (Icons.dark_mode, 'Map style', 'change the map background.'),
    (Icons.layers, 'Coverage', 'show or hide MeshMapper coverage.'),
    (Icons.cell_tower, 'Repeaters', 'show or hide repeater markers.'),
    (Icons.fence, 'Regions', 'show or hide regional boundaries.'),
    (
      Icons.my_location,
      'Location',
      'center the map on the GPS position and follow movement.'
    ),
    (
      Icons.navigation,
      'Direction',
      'keep north at the top or rotate with the direction of travel.'
    ),
    (Icons.sync_disabled, 'Rotation lock', 'prevent accidental map rotation.'),
    (
      Icons.info_outline,
      'Legend & Info',
      'explain coverage colors, marker types, and map symbols.'
    ),
  ];
  return OnboardingGuidePage(
    title: 'Map Tab Controls',
    accent: accent,
    children: [
      const GuideParagraph(
        'These buttons are on the Map tab. They control what appears on the map and how the map follows or rotates as you move.',
      ),
      for (final control in controls)
        GuideIconRow(
          icon: control.$1,
          title: control.$2,
          text: control.$3,
          color: accent,
        ),
      const GuideCallout(
        text: 'Tap a coverage square to see its mapping details.',
        icon: Icons.grid_view,
        color: accent,
      ),
      const GuideCallout(
        text:
            'Tap a repeater to see its identity, status, administrators, and management options.',
        icon: Icons.cell_tower,
        color: accent,
      ),
    ],
  );
}

Widget buildSmartPingingPage(BuildContext context) {
  const accent = Color(0xFF00897B);
  return const OnboardingGuidePage(
    title: 'Put Airtime Where It Helps',
    accent: accent,
    children: [
      GuideParagraph(
        'Smart Pinging avoids repeating work in map squares that already have recent coverage. It is enabled by default.',
      ),
      _VisualPanel(
        label:
            'Covered square, deferred ping, then uncovered square and sent ping',
        color: accent,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _MapSquare(icon: Icons.done_all, label: 'Covered', color: accent),
              _FlowArrow(label: 'Deferred'),
              _MapSquare(
                  icon: Icons.crop_square,
                  label: 'Uncovered',
                  color: Colors.orange),
              _FlowArrow(label: 'Sent'),
              Icon(Icons.send, color: accent),
            ],
          ),
        ),
      ),
      GuideIconRow(
        icon: Icons.pending_outlined,
        title: 'Deferred is normal',
        text:
            'The app holds one ping and sends it as soon as you enter a square without recent two-way or discovery coverage.',
        color: Colors.orange,
      ),
      GuideIconRow(
        icon: Icons.hearing,
        title: 'Listening continues',
        text:
            'Received mesh traffic is always recorded because listening adds coverage without transmitting. Manual pings and Trace Mode are not deferred by Smart Pinging.',
        color: accent,
      ),
      GuideCallout(
        text:
            'Regional administrators may require Smart Pinging in busy regions to reduce unnecessary airtime and protect normal mesh traffic.',
        icon: Icons.admin_panel_settings,
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.tune,
        title: 'Trail and settings',
        text:
            'Hollow trail markers show where a ping was deferred. Adjust the recent-coverage window under Settings > Wardriving.',
        color: accent,
      ),
    ],
  );
}

Widget buildCarpeaterPage(BuildContext context) {
  const accent = Color(0xFFE65100);
  return OnboardingGuidePage(
    title: 'Do You Travel With a Repeater?',
    accent: accent,
    children: [
      const GuideParagraph(
        'A CARpeater is a repeater travelling close to your companion, usually in the same vehicle. Its unusually strong nearby signal can create false coverage.',
      ),
      const _VisualPanel(
        label:
            'Companion and CARpeater in a vehicle with a fixed repeater outside',
        color: accent,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            children: [
              Column(
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(Icons.directions_car,
                          size: 88, color: Colors.blueGrey),
                      Row(children: [
                        Icon(Icons.memory, size: 18),
                        Icon(Icons.cell_tower, size: 18)
                      ]),
                    ],
                  ),
                  Text('Your vehicle'),
                ],
              ),
              SizedBox(width: 36),
              Icon(Icons.arrow_forward, color: accent),
              SizedBox(width: 36),
              Column(
                children: [
                  Icon(Icons.cell_tower, size: 60, color: Colors.green),
                  Text('Fixed repeater'),
                ],
              ),
            ],
          ),
        ),
      ),
      const GuideCallout(
        text:
            'If you do not travel with a repeater, there is nothing to configure.',
        icon: Icons.check_circle_outline,
        color: Colors.green,
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () async {
            await showCarpeaterSetupDialog(
              context,
              context.read<AppStateProvider>(),
            );
          },
          icon: const Icon(Icons.settings),
          label: const Text('Configure CARpeater'),
        ),
      ),
      const GuideCallout(
        text: 'Change this later under Settings > Wardriving > CARpeater.',
        icon: Icons.settings,
        color: accent,
      ),
      const GuideCallout(
        text:
            "Enable the filter and report your CARpeater's public key. Coverage involving an unreported CARpeater is dropped.",
        icon: Icons.key,
        color: accent,
      ),
      const GuideIconRow(
        icon: Icons.block,
        title: 'Direct CARpeater signal',
        text: 'Dropped',
        color: Colors.red,
      ),
      const GuideIconRow(
        icon: Icons.cell_tower,
        title: 'Fixed repeater behind it',
        text: 'Coverage counted',
        color: Colors.green,
      ),
      const GuideIconRow(
        icon: Icons.filter_alt,
        title: 'Other reported CARpeaters',
        text: 'Filtered from your results',
        color: Colors.blue,
      ),
      const GuideCallout(
        text:
            'While enabled, the public key is shared with MeshMapper so nearby wardrivers can filter the same CARpeater.',
        icon: Icons.public,
        color: Colors.blue,
      ),
      const GuideCallout(
        text:
            'Leave the strong-signal filter enabled unless you are certain no repeater travels near your companion. Turning it off can create false coverage.',
        icon: Icons.warning_amber,
        color: Colors.red,
      ),
    ],
  );
}

Widget buildBackgroundPage(BuildContext context) {
  final isIos = Theme.of(context).platform == TargetPlatform.iOS;
  const accent = Color(0xFF5E35B1);
  return OnboardingGuidePage(
    title: 'Keep Mapping in the Background',
    accent: accent,
    children: [
      const GuideParagraph(
        'MeshMapper can continue wardriving while the app is minimized or the screen is locked.',
      ),
      _VisualPanel(
        label: isIos
            ? 'Locked iPhone with Always location badge'
            : 'Locked Android phone with active wardriving notification',
        color: accent,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.phone_iphone, size: 68, color: accent),
              const SizedBox(width: 14),
              const Icon(Icons.lock, size: 34, color: accent),
              const SizedBox(width: 14),
              Chip(
                avatar: Icon(
                    isIos ? Icons.location_on : Icons.notifications_active,
                    color: accent),
                label: Text(isIos ? 'Always' : 'Session active'),
              ),
            ],
          ),
        ),
      ),
      if (isIos) ...[
        const GuideIconRow(
          icon: Icons.location_on,
          title: 'iPhone setup',
          text:
              'Background Location is required for reliable background wardriving. Open Settings > General > Background Location and allow location access Always.',
          color: accent,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: FilledButton.icon(
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => setUpBackgroundLocation(
              context,
              context.read<AppStateProvider>(),
            ),
            icon: const Icon(Icons.location_on),
            label: const Text('Set Up Background Location'),
          ),
        ),
      ] else ...[
        const GuideIconRow(
          icon: Icons.notifications_active,
          title: 'Android setup',
          text:
              'No additional background location permission is required. Allow MeshMapper notifications so you can see when the active mode keeps Bluetooth and GPS running.',
          color: accent,
        ),
      ],
      const GuideCallout(
        text:
            'Background operation does not start a wardriving session by itself. Stop the mode or disconnect when you are finished.',
        icon: Icons.stop_circle_outlined,
        color: accent,
      ),
    ],
  );
}

Widget buildResultsPage(BuildContext context) {
  const accent = Color(0xFF0277BD);
  final results = <(String, String, Color)>[
    (
      'BIDIR',
      'the message routed through the mesh and a repeat was heard.',
      PingColors.coverageBidir
    ),
    (
      'DISC',
      'a repeater answered a discovery request.',
      PingColors.coverageDisc
    ),
    (
      'TX',
      'the route succeeded, but no repeat was heard.',
      PingColors.coverageTx
    ),
    (
      'RX',
      'mesh traffic was heard without transmitting.',
      PingColors.coverageRx
    ),
    (
      'DEAD',
      'a repeater heard it, but no other radio received the repeat.',
      PingColors.coverageDead
    ),
    (
      'DROP',
      'no repeat was heard and the route did not succeed.',
      PingColors.coverageDrop
    ),
  ];
  return OnboardingGuidePage(
    title: 'See What You Mapped',
    accent: accent,
    children: [
      const _MapResultKindRow(
        swatchKey: ValueKey('guide-wardriving-marker-swatch'),
        title: 'Wardriving markers',
        text:
            'Dots show your TX, RX, discovery, trace, failed, and deferred events. Tap one for details.',
        color: accent,
        shape: BoxShape.circle,
      ),
      const _MapResultKindRow(
        swatchKey: ValueKey('guide-coverage-tile-swatch'),
        title: 'Coverage tiles',
        text:
            'Colored background squares summarize community coverage in that area. Tap one for details.',
        color: Colors.green,
        shape: BoxShape.rectangle,
      ),
      const GuideSectionLabel('Coverage tile colors'),
      for (final result in results)
        _CoverageLegendRow(
          key: ValueKey('guide-coverage-result-${result.$1}'),
          label: result.$1,
          description: result.$2,
          color: result.$3,
        ),
      const _GuideResultsDestinations(),
    ],
  );
}

class _MapResultKindRow extends StatelessWidget {
  const _MapResultKindRow({
    required this.swatchKey,
    required this.title,
    required this.text,
    required this.color,
    required this.shape,
  });

  final Key swatchKey;
  final String title;
  final String text;
  final Color color;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: swatchKey,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color,
              shape: shape,
              borderRadius:
                  shape == BoxShape.rectangle ? BorderRadius.circular(3) : null,
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.35,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideResultsDestinations extends StatelessWidget {
  const _GuideResultsDestinations();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('guide-results-destinations'),
      margin: const EdgeInsets.only(top: 2, bottom: 14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            const Expanded(
              child: _GuideResultDestination(
                icon: Icons.list_alt,
                title: 'Log',
                text: 'Events and errors',
              ),
            ),
            VerticalDivider(width: 1, color: colors.outlineVariant),
            const Expanded(
              child: _GuideResultDestination(
                icon: Icons.history,
                title: 'History',
                text: 'Saved sessions and routes',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideResultDestination extends StatelessWidget {
  const _GuideResultDestination({
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      child: Row(
        children: [
          Icon(icon, color: accent, size: 24),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                Text(
                  text,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverageLegendRow extends StatelessWidget {
  const _CoverageLegendRow({
    required this.label,
    required this.description,
    required this.color,
    super.key,
  });

  final String label;
  final String description;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: ValueKey('guide-coverage-swatch-$label'),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: textStyle,
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: description),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget buildOnlineOfflinePage(BuildContext context) {
  const accent = Color(0xFF00695C);
  return const OnboardingGuidePage(
    title: 'Choose Where Your Data Goes',
    accent: accent,
    children: [
      _VisualPanel(
        label: 'Online server cloud beside offline phone storage',
        color: accent,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Column(children: [
              Icon(Icons.cloud_upload, size: 54, color: accent),
              Text('Online')
            ]),
            Icon(Icons.swap_horiz, size: 34),
            Column(children: [
              Icon(Icons.phone_android, size: 54, color: Colors.blueGrey),
              Text('Offline')
            ]),
          ],
        ),
      ),
      GuideIconRow(
        icon: Icons.cloud_done,
        title: 'Online Mode',
        text:
            'Coverage is queued and uploaded to MeshMapper while you drive. Online Mode enables Hybrid and Active modes where allowed by your region. Smart Pinging is enabled by default.',
        color: accent,
      ),
      GuideCallout(
        text:
            'Before Hybrid or Active sends flood traffic, MeshMapper checks out a regional airtime slot. These slots limit simultaneous flood traffic and protect the mesh from excessive load.',
        icon: Icons.air,
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.phone_android,
        title: 'Offline Mode',
        text:
            'Coverage is saved locally on your phone instead of being uploaded. Only Passive and Trace modes are available. Use it when mobile data is poor, MeshMapper is undergoing maintenance, or you want to collect without sending anything yet.',
        color: Colors.blueGrey,
      ),
      GuideCallout(
        text:
            'Offline sessions are not uploaded automatically. When you are ready, open Settings > Data > Offline Sessions and choose Upload. You can also export or delete a saved session.',
        icon: Icons.upload_file,
        color: Colors.orange,
      ),
      GuideIconRow(
        icon: Icons.swap_horiz,
        title: 'Switch anytime',
        text:
            'Use Go Offline or Go Online on the Connect tab. You can switch before connecting or during a connected session.',
        color: accent,
      ),
      GuideCallout(
        text:
            'Hybrid and Active are unavailable offline because the app cannot reach MeshMapper to check out a regional airtime slot. Smart Pinging is also unavailable because the app cannot check recent server coverage.',
        icon: Icons.cloud_off,
        color: Colors.blueGrey,
      ),
    ],
  );
}

Widget buildPrivacyPage(BuildContext context) {
  const accent = Color(0xFF455A64);
  return const OnboardingGuidePage(
    title: 'Know What You Share',
    accent: accent,
    children: [
      GuideIconRow(
        icon: Icons.public,
        title: 'Public coverage',
        text:
            'Coverage collected in Online Mode contributes automatically to the public coverage maps. Coverage collected in Offline Mode contributes only after you manually upload the saved session.',
        color: Colors.green,
      ),
      GuideIconRow(
        icon: Icons.admin_panel_settings,
        title: 'Administrative review',
        text:
            'Regional administrators can review detailed GPS coordinates, radio model, and companion public key for data collected in regions they administer. Global administrators can review this information across MeshMapper. This access helps them investigate and remove inaccurate mapping data.',
        color: Colors.orange,
      ),
      GuideIconRow(
        icon: Icons.visibility_off,
        title: 'What the public sees',
        text:
            'The public coverage maps do not expose your individual coverage points, precise GPS coordinates, or companion public key. They show the resulting coverage without publicly displaying the detailed information behind each observation.',
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.cell_tower,
        title: 'Broadcast Coordinates',
        text:
            'Broadcast Coordinates is off by default. When it is off, your real location goes to the MeshMapper server but is not included in the wardriving message sent over the mesh. Turning it on allows other mesh users to receive the coordinates in that message.',
        color: Colors.blue,
      ),
      GuideIconRow(
        icon: Icons.person_off,
        title: 'Anonymous Mode',
        text:
            'Anonymous Mode hides your companion name and removes you from the public leaderboard. It does not make the device anonymous to MeshMapper. Its public key is still used to authenticate and associate the session.',
        color: accent,
      ),
    ],
  );
}

Widget buildAccountPage(BuildContext context) {
  const accent = Color(0xFF6A1B9A);
  return const OnboardingGuidePage(
    title: 'Own and Manage Your Mapping Data',
    accent: accent,
    children: [
      GuideParagraph(
        'Signing in to MyMeshMapper is optional, but linking your companion gives you control over the data it reports.',
      ),
      _VisualPanel(
        label: 'Signed challenge linking a radio and claimed repeater',
        color: accent,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Icon(Icons.memory, size: 42, color: accent),
            Icon(Icons.draw, size: 34),
            Icon(Icons.verified_user, size: 42, color: Colors.green),
            Icon(Icons.link, size: 34),
            Icon(Icons.cell_tower, size: 42, color: accent),
          ],
        ),
      ),
      GuideCallout(
        text:
            'When you link a connected companion, the app asks the radio to cryptographically sign a challenge. This proves that you control that companion without sharing its private key.',
        icon: Icons.verified_user,
        color: accent,
      ),
      GuideSectionLabel('MyMeshMapper allows you to:'),
      GuideBullet('See every companion linked to the account.'),
      GuideBullet(
          'View the data and coverage points your companions reported.'),
      GuideBullet('Delete coverage points from MeshMapper.'),
      GuideBullet('Track your mapping points and awards.'),
      GuideIconRow(
        icon: Icons.cell_tower,
        title: 'Claim and manage repeaters',
        text:
            'Select a repeater on the Map, tap Manage, sign in with its admin password, and tap Claim. Once claimed, your MyMeshMapper identity is publicly listed as an administrator. You can then add build and deployment information for that repeater through the MyMeshMapper portal.',
        color: accent,
      ),
      GuideCallout(
        text:
            'Open Settings > MeshMapper Account to sign in. Connect your companion afterward to link it.',
        icon: Icons.login,
        color: accent,
      ),
    ],
  );
}

Widget buildAutomaticUploadsPage(BuildContext context) {
  const accent = Color(0xFF0277BD);
  return const OnboardingGuidePage(
    title: 'Need Help?',
    accent: accent,
    children: [
      GuideIconRow(
        icon: Icons.feedback_outlined,
        title: 'Report a bug',
        text:
            'Open Settings > About & Support > Submit Feedback. Choose Bug, add a short title, explain what happened and the steps needed to reproduce it, then submit.',
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.bug_report,
        title: 'Debug logs',
        text:
            'If relevant debug logs are available, you can attach them to the report. Only include debug logs when you experienced an issue or a developer asked for them. Uploading debug logs does not upload your coverage data.',
        color: Colors.orange,
      ),
      GuideCallout(
        text:
            'Set up your radio and choose a mode before moving. Do not operate the app while driving.',
        icon: Icons.no_crash,
        color: Colors.red,
      ),
    ],
  );
}

class _DisconnectedConnectionPreview extends StatelessWidget {
  const _DisconnectedConnectionPreview();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ConnectionPreviewFrame(
      key: const ValueKey('guide-disconnected-connection-preview'),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Column(
              children: [
                Icon(
                  Icons.bluetooth,
                  size: 50,
                  color: colors.primary,
                ),
                const SizedBox(height: 10),
                Text(
                  'Last Connected Device',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  'MeshCore Radio',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 12),
                _PreviewActionButton(
                  icon: Icons.bluetooth_connected,
                  label: 'Reconnect',
                  color: colors.primary,
                  filled: true,
                  width: 170,
                ),
                const SizedBox(height: 5),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.bluetooth_searching,
                        size: 16, color: colors.primary),
                    const SizedBox(width: 4),
                    Text('Scan', style: TextStyle(color: colors.primary)),
                    const SizedBox(width: 20),
                    Icon(Icons.delete_outline,
                        size: 16, color: colors.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      'Forget',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Row(
              children: [
                const Expanded(
                  child: _PreviewActionButton(
                    icon: Icons.cloud_outlined,
                    label: 'Go Offline',
                    color: Colors.green,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _PreviewActionButton(
                    icon: Icons.bluetooth_searching,
                    label: 'Scan',
                    color: colors.primary,
                  ),
                ),
              ],
            ),
          ),
          _PreviewTransportPicker(primary: colors.primary),
          const _PreviewConnectionNavBar(connected: false),
        ],
      ),
    );
  }
}

class _ConnectedConnectionPreview extends StatelessWidget {
  const _ConnectedConnectionPreview();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ConnectionPreviewFrame(
      key: const ValueKey('guide-connected-connection-preview'),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.all(10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.bluetooth_connected,
                        color: Colors.green, size: 22),
                    SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'MeshCore Radio',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Connected',
                            style: TextStyle(
                              color: Colors.green,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 5,
                  children: [
                    _PreviewDetailChip(Icons.memory, 'Hardware'),
                    _PreviewDetailChip(Icons.code, 'Firmware'),
                    _PreviewDetailChip(Icons.developer_board, 'Platform'),
                  ],
                ),
                SizedBox(height: 10),
                _PreviewInfoRow(
                  label: 'Power Level',
                  icon: Icons.bolt,
                  value: '1.0 W  Auto',
                  color: Colors.orange,
                ),
                SizedBox(height: 8),
                _PreviewInfoRow(
                  label: 'Radio',
                  icon: Icons.radio,
                  value: 'Frequency  Bandwidth  SF  CR',
                  color: Colors.blue,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Row(
              children: [
                Expanded(
                  child: _PreviewActionButton(
                    icon: Icons.cloud_outlined,
                    label: 'Go Offline',
                    color: Colors.green,
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: _PreviewActionButton(
                    icon: Icons.link_off,
                    label: 'Disconnect',
                    color: Colors.red,
                  ),
                ),
              ],
            ),
          ),
          const _PreviewConnectionNavBar(connected: true),
        ],
      ),
    );
  }
}

class _ConnectionPreviewFrame extends StatelessWidget {
  const _ConnectionPreviewFrame({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Text(
              'Connection',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: colors.surfaceContainerLowest,
            child: const Row(
              children: [
                Expanded(
                  child: _PreviewStatusPill(
                    icon: Icons.location_on,
                    label: 'Regional Zone',
                    color: Colors.green,
                  ),
                ),
                SizedBox(width: 5),
                Expanded(
                  child: _PreviewStatusPill(
                    icon: Icons.flight,
                    label: 'Code',
                    color: Colors.blue,
                  ),
                ),
                SizedBox(width: 5),
                Expanded(
                  child: _PreviewStatusPill(
                    icon: Icons.group_outlined,
                    label: 'Open',
                    color: Colors.green,
                  ),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _PreviewStatusPill extends StatelessWidget {
  const _PreviewStatusPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewActionButton extends StatelessWidget {
  const _PreviewActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.filled = false,
    this.width,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool filled;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final button = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: filled ? 1 : 0.55)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 17, color: filled ? Colors.white : color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: filled ? Colors.white : color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (width == null) return button;
    return SizedBox(width: width, child: button);
  }
}

class _PreviewTransportPicker extends StatelessWidget {
  const _PreviewTransportPicker({required this.primary});

  final Color primary;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      decoration: BoxDecoration(
        border: Border.all(color: primary.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(9),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: Container(
              color: primary.withValues(alpha: 0.18),
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bluetooth, size: 15, color: primary),
                  const SizedBox(width: 5),
                  Text(
                    'BLE',
                    style: TextStyle(
                      color: primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lan,
                      size: 15,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 5),
                  Text(
                    'TCP',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewDetailChip extends StatelessWidget {
  const _PreviewDetailChip(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10)),
        ],
      ),
    );
  }
}

class _PreviewInfoRow extends StatelessWidget {
  const _PreviewInfoRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.color,
  });

  final String label;
  final IconData icon;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }
}

class _PreviewConnectionNavBar extends StatelessWidget {
  const _PreviewConnectionNavBar({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey(
        connected
            ? 'guide-connected-connection-nav'
            : 'guide-disconnected-connection-nav',
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          const Expanded(
            child: _PreviewConnectionNavItem(
              icon: Icons.map_outlined,
              label: 'Map',
            ),
          ),
          const Expanded(
            child: _PreviewConnectionNavItem(
              icon: Icons.list_alt_outlined,
              label: 'Log',
            ),
          ),
          const Expanded(
            child: _PreviewConnectionNavItem(
              icon: Icons.history_outlined,
              label: 'History',
            ),
          ),
          Expanded(
            child: _PreviewConnectionNavItem(
              icon: connected ? Icons.bluetooth_connected : Icons.bluetooth,
              label: connected ? 'Connected' : 'Connect',
              active: true,
              connected: connected,
            ),
          ),
          const Expanded(
            child: _PreviewConnectionNavItem(
              icon: Icons.settings_outlined,
              label: 'Settings',
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewConnectionNavItem extends StatelessWidget {
  const _PreviewConnectionNavItem({
    required this.icon,
    required this.label,
    this.active = false,
    this.connected = false,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final color = connected
        ? Colors.green
        : active
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: active ? FontWeight.w600 : null,
          ),
        ),
      ],
    );
  }
}

class _MapSquare extends StatelessWidget {
  const _MapSquare(
      {required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            border: Border.all(color: color, width: 2),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _FlowArrow extends StatelessWidget {
  const _FlowArrow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Column(
        children: [
          const Icon(Icons.arrow_forward, size: 20),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

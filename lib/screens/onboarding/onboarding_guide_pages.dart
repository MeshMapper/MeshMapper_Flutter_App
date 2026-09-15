import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../utils/ping_colors.dart';
import '../../widgets/background_location_setup.dart';
import '../../widgets/carpeater_setup_dialog.dart';

List<Widget> buildOnboardingGuidePages(BuildContext context) => [
      buildConnectPage(context),
      buildOnlineOfflinePage(context),
      buildPrivacyPage(context),
      buildAntennaPage(context),
      buildCarpeaterPage(context),
      buildBackgroundPage(context),
      buildModesPage(context),
      buildSmartPingingPage(context),
      buildMapControlsPage(context),
      buildResultsPage(context),
      buildAccountPage(context),
      buildHelpPage(context),
    ];

Color _guideAccent(BuildContext context, Color color) {
  if (Theme.of(context).brightness != Brightness.dark) return color;
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness(hsl.lightness.clamp(0.70, 1.0)).toColor();
}

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
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 44,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: _guideAccent(context, accent),
                    borderRadius: BorderRadius.circular(99),
                  ),
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
    final accent =
        _guideAccent(context, color ?? Theme.of(context).colorScheme.primary);
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
    final accent = _guideAccent(context, color ?? colors.primary);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
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
                          height: 1.4,
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
    final accent = _guideAccent(context, color ?? colors.primary);
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
    final accent = _guideAccent(context, color);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accent),
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
        'MeshMapper records mesh coverage as you travel. Start with a MeshCore radio running companion firmware, then open the Connect tab.',
      ),
      GuideIconRow(
        icon: Icons.radar,
        title: '1. Tap Scan',
        text: 'Turn on your radio and choose Bluetooth to find nearby radios.',
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.memory,
        title: '2. Select your radio',
        text: 'Choose the MeshCore companion you want to map with.',
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.check_circle_outline,
        title: '3. Wait for Connected',
        text:
            'MeshMapper checks your location and prepares the wardriving channel.',
        color: accent,
      ),
      _VisualPanel(
        label: 'First connection: choose Bluetooth and tap Scan',
        color: accent,
        child: _FirstConnectionPreview(),
      ),
      _GuideDetails(
        title: 'Find your way around',
        children: [
          GuideIconRow(
              icon: Icons.bluetooth,
              title: 'Connect',
              text:
                  'Connect your radio, check its details, or switch Online and Offline modes.'),
          GuideIconRow(
              icon: Icons.map_outlined,
              title: 'Map',
              text:
                  'Start and stop mapping, explore repeaters, and see coverage.'),
          GuideIconRow(
              icon: Icons.list_alt,
              title: 'Log',
              text: 'Check what your radio sent or heard and review errors.'),
          GuideIconRow(
              icon: Icons.history,
              title: 'History',
              text: 'Revisit saved mapping sessions and their routes.'),
          GuideIconRow(
              icon: Icons.settings_outlined,
              title: 'Settings',
              text:
                  'Adjust mapping preferences, manage saved data, and find help.'),
        ],
      ),
      _GuideDetails(
        title: 'Connection details',
        children: [
          GuideBullet(
              'TCP and USB are also available on supported devices. A previously connected radio is remembered for quicker reconnection.'),
          GuideBullet(
              "MeshMapper detects and reports the radio's expected power. It never changes the radio's actual transmit power."),
        ],
      ),
    ],
  );
}

class _GuideDetails extends StatelessWidget {
  const _GuideDetails({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        collapsedBackgroundColor:
            Theme.of(context).colorScheme.surfaceContainerLow,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        collapsedShape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        children: children,
      ),
    );
  }
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
                'The antenna is inside a metal vehicle cabin, metal box, or another enclosure that can reduce radio reception. Example: the radio and antenna are inside the car.',
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
                'The antenna is not enclosed by metal or another object that significantly blocks radio reception. Examples: a roof-mounted antenna, a handheld radio, or walking with the radio in a pocket.',
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
      const GuideParagraph(
          'Start with Passive Mode for general mapping. A zero-hop request reaches nearby repeaters directly, without forwarding. Flood messages are forwarded through the mesh.'),
      const GuideIconRow(
        icon: Icons.hearing,
        title: 'Passive Mode',
        text:
            'Sends a discovery request to nearby repeaters, which reply directly. It also listens for mesh traffic. This provides the best balance of broad mesh coverage and low airtime use.',
        color: accent,
      ),
      const GuideIconRow(
        icon: Icons.gps_fixed,
        title: 'Trace Mode',
        text:
            'Checks one selected repeater directly. Only that repeater responds. It uses the least airtime and is useful for antenna alignment or checking a specific repeater.',
        color: Colors.cyan,
      ),
      const GuideIconRow(
        icon: Icons.compare_arrows,
        title: 'Hybrid Mode',
        text:
            'Alternates between discovery requests and channel flood messages. Flood messages use more airtime because repeaters forward them through the mesh.',
        color: Colors.purple,
      ),
      GuideIconRow(
        icon: Icons.sensors,
        title: 'Active Mode',
        text:
            'Only sends channel flood messages through the mesh. It uses the most airtime and is the most aggressive mapping mode.',
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
    (Icons.dark_mode, 'Map style', 'Change the map background.'),
    (Icons.layers, 'Coverage', 'Show or hide MeshMapper coverage.'),
    (Icons.cell_tower, 'Repeaters', 'Show or hide repeater markers.'),
    (Icons.fence, 'Regions', 'Show or hide regional boundaries.'),
    (
      Icons.my_location,
      'Location',
      'Center the map on the GPS position and follow movement.'
    ),
    (
      Icons.navigation,
      'Direction',
      'Keep north at the top or rotate with the direction of travel.'
    ),
    (Icons.sync_disabled, 'Rotation lock', 'Prevent accidental map rotation.'),
    (
      Icons.info_outline,
      'Legend & Info',
      'Explain coverage colors, marker types, and map symbols.'
    ),
  ];
  return OnboardingGuidePage(
    title: 'Map Controls',
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
    title: 'Smart Pinging',
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
              _GuideIllustrationIcon(Icons.send, color: accent),
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
            "Enable the filter and add your CARpeater's public key (its radio ID). Coverage involving an unreported CARpeater is dropped.",
        icon: Icons.key,
        color: accent,
      ),
      const _GuideDetails(
        title: 'How CARpeater filtering works',
        children: [
          GuideIconRow(
            icon: Icons.block,
            title: 'Direct CARpeater signal',
            text: 'Dropped',
            color: Colors.red,
          ),
          GuideIconRow(
            icon: Icons.cell_tower,
            title: 'Fixed repeater behind it',
            text: 'Coverage counted',
            color: Colors.green,
          ),
          GuideIconRow(
            icon: Icons.filter_alt,
            title: 'Other reported CARpeaters',
            text: 'Filtered from your results',
            color: Colors.blue,
          ),
          GuideCallout(
            text:
                'While enabled, the public key is shared with MeshMapper so nearby wardrivers can filter the same CARpeater.',
            icon: Icons.public,
            color: Colors.blue,
          ),
        ],
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
              const _GuideIllustrationIcon(Icons.phone_iphone,
                  size: 68, color: accent),
              const SizedBox(width: 14),
              const _GuideIllustrationIcon(Icons.lock, size: 34, color: accent),
              const SizedBox(width: 14),
              Chip(
                avatar: _GuideIllustrationIcon(
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
              'Background Location is required for reliable background wardriving. In MeshMapper, open Settings > General > Background Location and allow location access Always.',
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
      'your channel message routed through the mesh to an observer and your radio heard a repeat. Happens in Active and Hybrid modes.',
      PingColors.coverageBidir
    ),
    (
      'DISC',
      'a repeater responded to your discovery or trace request. Happens in Passive, Hybrid, and Trace modes.',
      PingColors.coverageDisc
    ),
    (
      'TX',
      'your channel message reached an observer through the mesh, but your radio heard no repeats. Happens in Active and Hybrid modes.',
      PingColors.coverageTx
    ),
    (
      'RX',
      'your radio heard mesh traffic not generated from your own wardriving. Can happen in any mode.',
      PingColors.coverageRx
    ),
    (
      'DEAD',
      'your radio heard a repeat, but the message never reached an observer. Happens in Active and Hybrid modes.',
      PingColors.coverageDead
    ),
    (
      'DROP',
      'either no repeater was heard or no repeater responded to your discovery request. Happens in Active, Hybrid, and Passive modes.',
      PingColors.coverageDrop
    ),
  ];
  return OnboardingGuidePage(
    title: 'See What You Mapped',
    accent: accent,
    children: [
      const GuideParagraph(
          'Use the Map for coverage, the Log for individual events, and History to revisit a saved drive.'),
      const _MapResultKindRow(
        swatchKey: ValueKey('guide-wardriving-marker-swatch'),
        title: 'Wardriving markers',
        text:
            'Dots show what your app saw locally: TX, RX, discovery, trace, failed, and deferred events. A green dot means your radio heard a repeat, but the tile color depends on what the MeshMapper servers observed. Markers and tiles show two different things. Tap one for details.',
        color: accent,
        shape: BoxShape.circle,
      ),
      const _MapResultKindRow(
        swatchKey: ValueKey('guide-coverage-tile-swatch'),
        title: 'Coverage tiles',
        text:
            'Colored background squares summarize what the MeshMapper servers observed for community coverage in that area. Tap one for details.',
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
                        height: 1.4,
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
                text: 'Review sent and received events or check an error.',
              ),
            ),
            VerticalDivider(width: 1, color: colors.outlineVariant),
            const Expanded(
              child: _GuideResultDestination(
                icon: Icons.history,
                title: 'History',
                text: 'Open a saved session to revisit its route and markers.',
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
      GuideParagraph(
          'Choose Online for automatic uploads or Offline to save coverage on your phone for later.'),
      GuideIconRow(
        icon: Icons.cloud_done,
        title: 'Online Mode',
        text:
            'Coverage is queued and uploaded to MeshMapper while you drive. Online Mode enables Hybrid and Active modes where allowed by your region. Smart Pinging is enabled by default.',
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.phone_android,
        title: 'Offline Mode',
        text:
            'Coverage is saved locally on your phone instead of being uploaded. Only Passive and Trace modes are available. Use it when mobile data is poor, MeshMapper is undergoing maintenance, or you want to collect without uploading coverage to MeshMapper yet.',
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
      _GuideDetails(
        title: 'Why modes differ offline',
        children: [
          GuideCallout(
            text:
                'Before Hybrid or Active sends flood traffic, MeshMapper checks out a regional airtime slot. These slots limit simultaneous flood traffic and protect the mesh from excessive load.',
            icon: Icons.air,
            color: accent,
          ),
          GuideCallout(
            text:
                'Hybrid and Active are unavailable offline because the app cannot reach MeshMapper to check out a regional airtime slot. Smart Pinging is also unavailable because the app cannot check recent server coverage.',
            icon: Icons.cloud_off,
            color: Colors.blueGrey,
          ),
        ],
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
      GuideParagraph(
          'Review how MeshMapper shares coverage and location details before you start mapping.'),
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
            'The public coverage maps do not expose your individual coverage points, precise GPS coordinates, or companion public key.',
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.cell_tower,
        title: 'Broadcast My Coordinates',
        text:
            'Off by default: your location goes to MeshMapper, but is not included in the wardriving message sent over the mesh. Turn it on to include your coordinates in that message.',
        color: Colors.blue,
      ),
      GuideIconRow(
        icon: Icons.person_off,
        title: 'Anonymous Mode',
        text:
            'Anonymous Mode hides your companion name and removes you from the public leaderboard. It does not make the device anonymous to MeshMapper. Its public key is still used to authenticate and associate the session.',
        color: accent,
      ),
      GuideCallout(
          text: 'Find these controls under Settings > Wardriving.',
          icon: Icons.settings,
          color: accent),
    ],
  );
}

Widget buildAccountPage(BuildContext context) {
  const accent = Color(0xFF6A1B9A);
  return const OnboardingGuidePage(
    title: 'Your MeshMapper Account',
    accent: accent,
    children: [
      GuideParagraph(
        'Signing in to MyMeshMapper is optional, but linking your companion gives you control over the data it reports.',
      ),
      GuideSectionLabel('MyMeshMapper allows you to:'),
      GuideBullet('See every companion linked to the account.'),
      GuideBullet(
          'View the data and coverage points your companions reported.'),
      GuideBullet('Delete coverage points from MeshMapper.'),
      GuideBullet('Track your mapping points and awards.'),
      GuideBullet('Claim and manage repeaters you administer.'),
      _GuideDetails(
        title: 'How to claim a repeater',
        children: [
          GuideBullet(
              'Select a repeater on the Map, tap Manage, sign in with its admin password, and tap Claim.'),
          GuideBullet(
              'Once claimed, your MyMeshMapper identity is publicly listed as an administrator.'),
          GuideBullet(
              'You can then add build and deployment information for that repeater through the MyMeshMapper portal.'),
        ],
      ),
      _GuideDetails(
        title: 'How linking protects your radio',
        children: [
          GuideBullet(
              'The app asks your connected radio to cryptographically sign a challenge. This proves you control it without sharing its private key.'),
        ],
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

Widget buildHelpPage(BuildContext context) {
  const accent = Color(0xFF0277BD);
  return const OnboardingGuidePage(
    title: 'Ready to Map',
    accent: accent,
    children: [
      GuideParagraph(
          'You are ready for your first session. Set everything up while you are parked.'),
      GuideSectionLabel('Before you start'),
      GuideBullet('Connect your radio and choose Online or Offline.'),
      GuideBullet(
          'Set External Antenna to Yes or No. Configure a CARpeater if one travels with you.'),
      GuideBullet(
          'On the Map, start Passive Mode for general mapping. Tap the running mode again to stop.'),
      GuideSectionLabel('Need help?'),
      GuideIconRow(
        icon: Icons.feedback_outlined,
        title: 'Report a bug',
        text:
            'Open Settings > About & Support > Submit Feedback. Choose Bug, add a short title, explain what happened and the steps needed to reproduce it, then submit.',
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.menu_book,
        title: 'Reopen this guide',
        text: 'Open Settings > About & Support > Quick Guide anytime.',
        color: accent,
      ),
      _GuideDetails(title: 'Including debug logs', children: [
        GuideIconRow(
          icon: Icons.bug_report,
          title: 'Debug logs',
          text:
              'If relevant debug logs are available, you can attach them to the report. Only include debug logs when you experienced an issue or a developer asked for them. Uploading debug logs does not upload your coverage data.',
          color: Colors.orange,
        ),
      ]),
      GuideCallout(
        text:
            'Set up your radio and choose a mode before moving. Do not operate the app while driving.',
        icon: Icons.no_crash,
        color: Colors.red,
      ),
    ],
  );
}

class _FirstConnectionPreview extends StatelessWidget {
  const _FirstConnectionPreview();

  @override
  Widget build(BuildContext context) {
    final accent = _guideAccent(context, Theme.of(context).colorScheme.primary);
    return Column(
      key: const ValueKey('guide-first-connection-preview'),
      children: [
        Row(children: [
          Icon(Icons.bluetooth, color: accent),
          const SizedBox(width: 10),
          Text('Bluetooth', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          Icon(Icons.check_circle, color: accent, size: 20),
        ]),
        const SizedBox(height: 14),
        const Text('Tap Scan to search for MeshCore devices'),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.bluetooth_searching, color: accent, size: 20),
            const SizedBox(width: 8),
            Text('Scan',
                style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
          ]),
        ),
      ],
    );
  }
}

class _GuideIllustrationIcon extends StatelessWidget {
  const _GuideIllustrationIcon(this.icon, {required this.color, this.size});
  final IconData icon;
  final Color color;
  final double? size;

  @override
  Widget build(BuildContext context) =>
      Icon(icon, color: _guideAccent(context, color), size: size);
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
            color: _guideAccent(context, color).withValues(alpha: 0.15),
            border: Border.all(color: _guideAccent(context, color), width: 2),
          ),
          child: Icon(icon, color: _guideAccent(context, color)),
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

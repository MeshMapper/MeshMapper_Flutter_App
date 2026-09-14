import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../utils/ping_colors.dart';
import '../../widgets/background_location_setup.dart';

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
  return OnboardingGuidePage(
    title: 'Connect Your MeshCore Radio',
    accent: accent,
    children: [
      const GuideParagraph(
        'Open the Connect tab and choose how your radio is connected. Bluetooth is the usual choice. TCP and USB may also be available on supported devices.',
      ),
      _VisualPanel(
        label: 'Connect tab, radio result, and Connected status',
        color: accent,
        child: Column(
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _MiniNav(icon: Icons.map_outlined, label: 'Map'),
                _MiniNav(icon: Icons.link, label: 'Connect', active: true),
                _MiniNav(icon: Icons.list_alt, label: 'Log'),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.bluetooth_searching, color: Colors.blue),
                const SizedBox(width: 10),
                const Expanded(child: Text('MeshCore companion')),
                Chip(
                  avatar:
                      const Icon(Icons.check_circle, size: 18, color: accent),
                  label: const Text('Connected'),
                  backgroundColor: accent.withValues(alpha: 0.12),
                ),
              ],
            ),
          ],
        ),
      ),
      const GuideIconRow(
          icon: Icons.radar, title: '1. Tap Scan', text: 'Find nearby radios.'),
      const GuideIconRow(
        icon: Icons.memory,
        title: '2. Select your MeshCore companion',
        text: 'Choose the radio you want to map with.',
      ),
      const GuideIconRow(
        icon: Icons.check_circle_outline,
        title: '3. Wait for Connected',
        text: 'The setup steps finish before wardriving controls are enabled.',
        color: accent,
      ),
      const GuideParagraph(
        'MeshMapper checks your GPS location, signs into your regional zone, prepares the wardriving channel, and detects your radio model. A previously connected radio will be remembered for quicker reconnection.',
      ),
      const GuideCallout(
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
      GuideParagraph(
        'Choose Yes or No on the Map screen before starting a mode.',
        emphasis: true,
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
      _VisualPanel(
        label: 'Four wardriving mode cards with Passive Mode emphasized',
        color: accent,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            const _ModeBadge(
              label: 'Passive',
              icon: Icons.radar,
              color: accent,
              emphasized: true,
            ),
            const _ModeBadge(
              label: 'Hybrid',
              icon: Icons.compare_arrows,
              color: Colors.purple,
            ),
            _ModeBadge(
              label: 'Active',
              icon: Icons.campaign,
              color: PingColors.txSuccess,
            ),
            _ModeBadge(
              label: 'Trace',
              icon: Icons.route,
              color: PingColors.traceSuccess,
            ),
          ],
        ),
      ),
      const GuideIconRow(
        icon: Icons.radar,
        title: 'Passive Mode',
        text:
            'Sends nearby discovery requests and continuously listens for received mesh traffic. It creates useful coverage data with low mesh impact and is the normal choice for mapping most regions.',
        color: accent,
      ),
      const GuideIconRow(
        icon: Icons.compare_arrows,
        title: 'Hybrid Mode',
        text:
            'Alternates between Active wardriving pings and discovery requests. Like Active Mode, it only appears where the regional administrator allows flood traffic.',
        color: Colors.purple,
      ),
      GuideIconRow(
        icon: Icons.campaign,
        title: 'Active Mode',
        text:
            'Sends regular wardriving messages through the mesh and records which repeaters hear them. Active Mode is disabled and hidden in most regions because it can significantly increase mesh utilization. It only appears when the regional administrator chooses to enable it.',
        color: PingColors.txSuccess,
      ),
      GuideIconRow(
        icon: Icons.route,
        title: 'Trace Mode',
        text:
            'Tests the signal path to one selected repeater. It is useful for antenna alignment or checking a specific node.',
        color: PingColors.traceSuccess,
      ),
      const GuideCallout(
        text:
            'Most regions only show Passive and Trace modes. This is expected. Passive Mode still sends discovery requests, listens for received mesh traffic, and does a great job mapping the mesh.',
        icon: Icons.public,
        color: accent,
      ),
      const GuideParagraph(
        'Tap a mode to start it and tap the running mode again to stop. Wait for Stopping to finish before disconnecting. Status text explains when the app is waiting for GPS, movement, cooldown, or a regional rule.',
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
    title: 'Control What You See',
    accent: accent,
    children: [
      _VisualPanel(
        label: 'Map toolbar controls in app order',
        color: accent,
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            for (final control in controls)
              Tooltip(
                message: control.$2,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(control.$1, color: accent),
                ),
              ),
          ],
        ),
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
      const GuideParagraph(
        'Use the ? button on the wardriving control panel to reopen help for the antenna and mode buttons.',
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
        'Smart Pinging avoids repeating work in map squares that already have recent coverage. It is enabled by default and may be required by your regional administrator.',
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
      GuideParagraph(
        'If the control says Deferred, the app is working normally. It holds one ping and sends it as soon as you enter a square without recent two-way or discovery coverage.',
      ),
      GuideCallout(
        text:
            'MeshMapper also requires at least 25 metres of movement between automatic attempts. If you see Move 25 m, continue travelling and the session will resume automatically.',
        icon: Icons.straighten,
        color: Colors.orange,
      ),
      GuideParagraph(
        'Received mesh traffic is always recorded because listening adds coverage without transmitting. Manual pings and Trace Mode are not deferred by Smart Pinging.',
      ),
      GuideCallout(
        text:
            'Regional administrators may require Smart Pinging in busy regions to reduce unnecessary airtime and protect normal mesh traffic.',
        icon: Icons.admin_panel_settings,
        color: accent,
      ),
      GuideParagraph(
        'Hollow trail markers show where a ping was deferred. You can adjust the recent-coverage window under Settings > Wardriving.',
      ),
    ],
  );
}

Widget buildCarpeaterPage(BuildContext context) {
  const accent = Color(0xFFE65100);
  return const OnboardingGuidePage(
    title: 'Do You Travel With a Repeater?',
    accent: accent,
    children: [
      GuideParagraph(
        'A CARpeater is a repeater travelling close to your companion, usually in the same vehicle. Its unusually strong nearby signal can create false coverage.',
      ),
      _VisualPanel(
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
      GuideCallout(
        text:
            'If you do not travel with a repeater, there is nothing to configure.',
        icon: Icons.check_circle_outline,
        color: Colors.green,
      ),
      GuideParagraph(
        'Enable the CARpeater Filter and report its full public key in Settings > Wardriving > CARpeater.',
        emphasis: true,
      ),
      GuideParagraph(
        'MeshMapper can only use valid data passing through your CARpeater when you have enabled the filter and reported which repeater is yours. The app removes your CARpeater from the route and credits the fixed repeater behind it.',
      ),
      GuideParagraph(
        'If your CARpeater is not reported, its signals look like unreliable, excessively strong readings and the data is dropped.',
      ),
      GuideBullet(
          "A direct reading from only the user's CARpeater is dropped."),
      GuideBullet(
          "A route through the user's CARpeater can still contribute coverage for the repeater behind it."),
      GuideBullet(
          "Other reported CARpeaters in the region are filtered from the user's results."),
      GuideParagraph(
        'Your CARpeater public key is shared with MeshMapper while the filter is enabled. This allows other wardrivers in your region to filter the same CARpeater too.',
      ),
      GuideCallout(
        text:
            'Do not disable the strong-signal RSSI filter unless you are certain there is no co-located repeater nearby. Incorrect settings can create false coverage data.',
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
        const GuideParagraph(
          'Background Location is required for reliable background wardriving. Open Settings > General > Background Location and allow location access Always.',
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
        const GuideParagraph(
          'No additional background location permission is required. MeshMapper uses a persistent notification while a wardriving mode is active to keep Bluetooth and GPS running.',
        ),
        const GuideParagraph(
          'Allow MeshMapper notifications so you can see when the background session is active.',
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
      'the message routed through the mesh and a repeat was heard back.',
      PingColors.coverageBidir
    ),
    (
      'DISC',
      'a repeater answered a discovery request.',
      PingColors.coverageDisc
    ),
    (
      'TX',
      'the message routed successfully, but no repeat was heard back.',
      PingColors.coverageTx
    ),
    (
      'RX',
      'the radio heard mesh traffic without transmitting.',
      PingColors.coverageRx
    ),
    (
      'DEAD',
      'the attempt did not produce confirmed coverage.',
      PingColors.coverageDead
    ),
    (
      'DROP',
      'the attempt did not produce confirmed coverage.',
      PingColors.coverageDrop
    ),
  ];
  return OnboardingGuidePage(
    title: 'See What You Mapped',
    accent: accent,
    children: [
      const GuideParagraph(
        'New observations appear on the Map as you travel. Tap a marker or coverage square to see its details, route, signal information, and repeaters.',
      ),
      _VisualPanel(
        label:
            'MeshMapper result colors for BIDIR, DISC, TX, RX, DEAD, and DROP',
        color: accent,
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final result in results)
              SizedBox(
                width: 160,
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: result.$3,
                        borderRadius:
                            BorderRadius.circular(result.$1 == 'DISC' ? 12 : 4),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(result.$1,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
          ],
        ),
      ),
      for (final result in results)
        GuideBullet('${result.$1}: ${result.$2}', icon: Icons.square),
      const GuideIconRow(
        icon: Icons.list_alt,
        title: 'Log',
        text:
            'The Log tab shows every TX, RX, discovery, and trace event. The Errors section explains dropped data, connection problems, and CARpeater filtering.',
        color: accent,
      ),
      const GuideIconRow(
        icon: Icons.history,
        title: 'History',
        text:
            'The History tab saves automatic wardriving sessions. Open a session to review its route on the map, event timeline, and noise-floor graph.',
        color: accent,
      ),
    ],
  );
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
            'Coverage is queued and uploaded to MeshMapper while you drive. Online Mode checks your regional rules and can use existing coverage for Smart Pinging.',
        color: accent,
      ),
      GuideIconRow(
        icon: Icons.phone_android,
        title: 'Offline Mode',
        text:
            'Coverage is saved locally on your phone instead of being uploaded. Use it when mobile data is poor, MeshMapper is undergoing maintenance, or you want to collect without sending anything yet.',
        color: Colors.blueGrey,
      ),
      GuideCallout(
        text:
            'Offline sessions are not uploaded automatically. When you are ready, open Settings > Data > Offline Sessions and choose Upload. You can also export or delete a saved session.',
        icon: Icons.upload_file,
        color: Colors.orange,
      ),
      GuideParagraph(
        'Use Go Offline or Go Online on the Connect tab. You can switch before connecting or during a connected session.',
      ),
      GuideParagraph(
        'Smart Pinging is unavailable in Offline Mode because the app cannot check recent server coverage.',
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
            'In Online Mode, GPS-tagged coverage is uploaded to MeshMapper and contributes to the public community map.',
        color: Colors.green,
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
      GuideCallout(
        text:
            'Set up your radio and choose a mode before moving. Do not operate the app while driving.',
        icon: Icons.no_crash,
        color: Colors.red,
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
      GuideParagraph(
        'When you link a connected companion, the app asks the radio to cryptographically sign a challenge. This proves that you control that companion without sharing its private key.',
      ),
      GuideBullet('See every companion linked to the account.'),
      GuideBullet('View the data and coverage points they reported.'),
      GuideBullet('Delete coverage points from the MeshMapper servers.'),
      GuideBullet('Track mapping points and awards.'),
      GuideBullet('Claim repeaters the user administers.'),
      GuideBullet(
        'Add build and deployment information for administered repeaters through the MyMeshMapper portal.',
      ),
      GuideParagraph(
        'Select a repeater on the Map, tap Manage, sign in with its admin password, and tap Claim. Your MyMeshMapper identity will then be publicly listed as an administrator of that repeater.',
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
  const accent = Color(0xFF2E7D32);
  return const OnboardingGuidePage(
    title: 'Just Choose a Mode and Drive',
    accent: accent,
    children: [
      _VisualPanel(
        label: 'Automatic coverage uploads separated from support debug logs',
        color: accent,
        child: Column(
          children: [
            _PathRow(
              icon: Icons.route,
              label: 'Coverage uploads automatically',
              color: accent,
            ),
            Divider(height: 24),
            _PathRow(
              icon: Icons.bug_report,
              label: 'Debug logs are for support only',
              color: Colors.orange,
            ),
          ],
        ),
      ),
      GuideParagraph(
        'When an Online Mode session is running, MeshMapper automatically sends your coverage data to the server. All you need to do is drive with a wardriving mode enabled.',
      ),
      GuideParagraph(
        'If your connection is temporarily unavailable, coverage waits in the queue and retries automatically. You do not need to upload it yourself.',
      ),
      GuideCallout(
        text:
            'Offline Mode is the only exception. Upload those saved sessions later from Settings > Data > Offline Sessions.',
        icon: Icons.phone_android,
        color: Colors.blueGrey,
      ),
      GuideCallout(
        text:
            'Uploading Debug Logs does not upload your coverage. Debug logs are diagnostic files used to investigate app problems.',
        icon: Icons.bug_report,
        color: Colors.orange,
      ),
      GuideParagraph(
        'Only upload debug logs when you have experienced an issue or a developer has asked you to provide them.',
      ),
    ],
  );
}

class _MiniNav extends StatelessWidget {
  const _MiniNav(
      {required this.icon, required this.label, this.active = false});
  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      children: [
        Icon(icon, color: color),
        Text(label,
            style: TextStyle(
                color: color, fontWeight: active ? FontWeight.bold : null)),
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

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({
    required this.label,
    required this.icon,
    required this.color,
    this.emphasized = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 112,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: emphasized ? 0.2 : 0.07),
        border: Border.all(color: color, width: emphasized ? 2 : 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 5),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
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

class _PathRow extends StatelessWidget {
  const _PathRow(
      {required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color),
        Expanded(
            child:
                Divider(indent: 8, endIndent: 8, color: color, thickness: 2)),
        Icon(Icons.arrow_forward, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

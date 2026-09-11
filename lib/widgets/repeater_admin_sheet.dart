import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/repeater_admin/repeater_admin_api.dart';
import '../services/repeater_admin/repeater_admin_models.dart';
import '../models/repeater.dart';
import '../services/repeater_admin/repeater_admin_session.dart';
import '../utils/debug_logger_io.dart';
import '../utils/ping_colors.dart';
import 'app_toast.dart';

/// Which tap set [RepeaterAdminSession.lastError]. The session keeps one
/// error field, so the sheet remembers whose it is and shows it under the
/// card the user just used.
enum _ErrorOwner { none, login, route, neighbours }

/// Open the Manage sheet for [target]. Refuses (with a toast) when the
/// provider cannot open a session right now.
Future<void> showRepeaterAdminSheet(
    BuildContext context, RepeaterTarget target) async {
  final appState = context.read<AppStateProvider>();
  final session = await appState.openRepeaterAdminSession(target);
  if (!context.mounted) {
    // The session is already open, so bowing out here without closing it
    // would leave the ping controls locked with no sheet (Rule 7).
    await appState.closeRepeaterAdminSession();
    return;
  }
  if (session == null) {
    AppToast.error(context,
        appState.repeaterAdminBlockReason ?? 'Cannot manage this repeater right now');
    return;
  }
  final remembered = await appState.readRepeaterPassword(target.hexId);
  if (!context.mounted) {
    await appState.closeRepeaterAdminSession();
    return;
  }
  debugLog('[RADMIN] Manage sheet opened for ${target.shortId}');
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Same ground as the repeater detail sheet on the map, so Manage reads
    // as the next page of the same thing.
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _RepeaterAdminBody(
        session: session,
        rememberedPassword: remembered,
        scrollController: scrollController,
      ),
    ),
  ).whenComplete(() {
    debugLog('[RADMIN] Manage sheet closed for ${target.shortId}');
    unawaited(appState.closeRepeaterAdminSession());
  });
}

class _RepeaterAdminBody extends StatefulWidget {
  final RepeaterAdminSession session;
  final String? rememberedPassword;
  final ScrollController scrollController;

  const _RepeaterAdminBody({
    required this.session,
    required this.rememberedPassword,
    required this.scrollController,
  });

  @override
  State<_RepeaterAdminBody> createState() => _RepeaterAdminBodyState();
}

class _RepeaterAdminBodyState extends State<_RepeaterAdminBody> {
  late final TextEditingController _password;
  late bool _remember;
  late bool _hasRemembered;
  bool _showPassword = false;
  RepeaterAdminResult? _claimResult;
  RepeaterAdminResult? _uploadResult;
  // What the last successful upload sent: the page stamp and the row count.
  // While the list is unchanged the Upload button stays greyed out and reads
  // "Uploaded", so a fast round trip still visibly lands. A fetch or a load
  // more changes one of these and the button comes back.
  DateTime? _uploadedStamp;
  int _uploadedHeld = 0;
  String? _claimError;
  bool _serverBusy = false;
  bool _dismissing = false;
  _ErrorOwner _errorOwner = _ErrorOwner.none;

  RepeaterAdminSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _password = TextEditingController(text: widget.rememberedPassword ?? '');
    _hasRemembered = widget.rememberedPassword != null;
    _remember = _hasRemembered;
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final appState = context.read<AppStateProvider>();
    setState(() => _errorOwner = _ErrorOwner.login);
    final text = _password.text;
    final ok = await session.login(text);
    if (!mounted) return;
    if (session.isLoggedIn && _remember) {
      await appState.rememberRepeaterPassword(session.target.hexId, text);
      if (!mounted) return;
      _hasRemembered = true;
    }
    if (ok) _claimError = null;
    if (mounted) setState(() {});
  }

  Future<void> _forget() async {
    final appState = context.read<AppStateProvider>();
    await appState.forgetRepeaterPassword(session.target.hexId);
    if (!mounted) return;
    setState(() {
      _password.clear();
      _remember = false;
      _hasRemembered = false;
    });
  }

  Future<void> _resetRoute() async {
    setState(() => _errorOwner = _ErrorOwner.route);
    await session.resetRoute();
    if (mounted) setState(() {});
  }

  Future<void> _claim() async {
    final appState = context.read<AppStateProvider>();
    setState(() {
      // The claim runs over the mesh and can set the session's lastError. It
      // belongs to this card's own line, so no card owns the session's copy.
      _errorOwner = _ErrorOwner.none;
      _serverBusy = true;
      _claimError = null;
    });
    final result = await appState.claimRepeater();
    if (!mounted) return;
    setState(() {
      _serverBusy = false;
      _claimResult = result.ok ? result : null;
      _claimError = result.ok ? null : (result.message ?? result.userMessage);
    });
  }

  Future<void> _unclaim() async {
    final appState = context.read<AppStateProvider>();
    setState(() {
      _errorOwner = _ErrorOwner.none;
      _serverBusy = true;
    });
    final result = await appState.unclaimRepeater(session.target.hexId);
    if (!mounted) return;
    setState(() {
      _serverBusy = false;
      _claimResult = null;
      _claimError = result.ok ? null : result.userMessage;
    });
  }

  Future<void> _upload() async {
    final appState = context.read<AppStateProvider>();
    setState(() {
      _errorOwner = _ErrorOwner.none;
      _serverBusy = true;
    });
    final result = await appState.uploadRepeaterNeighbours();
    if (!mounted) return;
    setState(() {
      _serverBusy = false;
      _uploadResult = result;
      if (result.ok) {
        _uploadedStamp = session.neighboursFetchedAt;
        _uploadedHeld = session.neighbours.length;
      }
    });
    if (result.ok) {
      AppToast.success(context,
          'Neighbours uploaded (${result.resolved ?? 0} resolved, ${result.unresolved ?? 0} unknown)');
    }
  }

  Future<void> _fetchNeighbours() async {
    setState(() => _errorOwner = _ErrorOwner.neighbours);
    await session.fetchNeighbours();
  }

  Future<void> _loadMoreNeighbours() async {
    setState(() => _errorOwner = _ErrorOwner.neighbours);
    await session.loadMoreNeighbours();
  }

  @override
  Widget build(BuildContext context) {
    final live = context.select((AppStateProvider p) => p.repeaterAdminSession);
    if (live == null || session.closed) {
      // The session is gone. Either the sheet is already closing (the normal
      // close empties the session and the sheet builds once more during its
      // exit animation), or it died under an open sheet (a BLE drop). Only
      // the second case needs anything: pop, and say why in a toast when the
      // radio is what went away.
      final route = ModalRoute.of(context);
      final closing = route == null || !route.isCurrent;
      if (!closing && !_dismissing) {
        _dismissing = true;
        final radioGone = !context.read<AppStateProvider>().isConnected;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // Toast first: it resolves the app's ScaffoldMessenger through
          // this context, which is gone once the sheet has popped.
          if (radioGone) AppToast.error(context, 'The radio disconnected.');
          final nav = Navigator.of(context);
          if (nav.canPop()) nav.pop();
        });
      }
      return const SizedBox(height: 120);
    }
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final appState = context.read<AppStateProvider>();
        final rep = appState.repeaters
            .where((r) => r.hexId.toUpperCase() == session.target.hexId)
            .toList();
        final admins = rep.isEmpty ? const <String>[] : rep.first.admins;
        final claimed = appState.isRepeaterClaimed(session.target.hexId) ||
            _claimResult != null;
        final badgeColor = _badgeColor(rep.isEmpty ? null : rep.first);
        return ListView(
          controller: widget.scrollController,
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, 24 + MediaQuery.of(context).viewPadding.bottom),
          children: [
            _header(context, badgeColor),
            const SizedBox(height: 16),
            // The card goes away once admin: the header says so, and the
            // session cannot be re-logged without closing the sheet anyway.
            // A guest still needs it, to enter the admin password.
            if (!session.isAdmin) _loginCard(context),
            if (session.isAdmin) ...[
              _claimCard(context, claimed, admins),
              _neighboursCard(context),
            ],
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // Header: the map sheet's round ID badge, coloured by the session state.
  // ---------------------------------------------------------------------

  // A login in flight reads as still not logged in: the Log in button
  // already says "Logging in" with a spinner, so the header does not.
  (String, Color) _stateLabel(BuildContext context) => switch (session.state) {
        RepeaterAdminState.idle ||
        RepeaterAdminState.ensuringContact ||
        RepeaterAdminState.loggingIn =>
          ('Not logged in', const Color(0xFF64748B)),
        RepeaterAdminState.admin => (
            'Logged in as admin',
            Theme.of(context).colorScheme.primary
          ),
        RepeaterAdminState.guest => ('Logged in as guest', const Color(0xFFD97706)),
        RepeaterAdminState.failed => (
            'Login failed',
            Theme.of(context).colorScheme.error
          ),
      };

  /// The badge is the repeater's marker colour, the same rule the map's
  /// detail sheet uses (dead, new, else active), so the two sheets agree.
  /// A repeater the zone list does not carry gets the active colour.
  static Color _badgeColor(Repeater? r) {
    if (r == null) return PingColors.repeaterActive;
    if (r.isDead) return PingColors.repeaterDead;
    if (r.isNew) return PingColors.repeaterNew;
    return PingColors.repeaterActive;
  }

  Widget _header(BuildContext context, Color badgeColor) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = _stateLabel(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              constraints: const BoxConstraints(minWidth: 44),
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white, width: 2),
              ),
              alignment: Alignment.center,
              child: Text(
                session.target.shortId,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // One line, always: a long name shrinks to fit rather
                  // than wrapping the header onto a second row.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      session.target.name,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: color)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.pop(context),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Close',
            ),
          ],
        ),
        // The only fact worth a line up here is the route the radio is
        // using. It is always shown, so the header never changes shape.
        // Reset route sits beside it until a login succeeds, because the
        // route only matters for getting the login through: the radio sends
        // it DIRECT along a learned route and never falls back to flood, so
        // a stale route is silent exactly like a wrong password. Once logged
        // in the route cannot change for the session, so the line is
        // read-only. The key is the badge; who administers the repeater is
        // the Claim card's story.
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.5)),
          ),
          child: Column(children: [
            Row(children: [
              Expanded(child: _routeLine(context)),
              if (!session.isLoggedIn && session.route != null)
                TextButton(
                  onPressed: session.busy ? null : _resetRoute,
                  style:
                      TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Reset route'),
                ),
            ]),
            if (_ownedError(_ErrorOwner.route) case final w?) w,
          ]),
        ),
      ],
    );
  }

  /// The route as the radio holds it: hop hashes only, with a Details
  /// button that lists the hops by name. Flood and Direct have no hops and
  /// no button.
  Widget _routeLine(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final known = session.route;
    final route = known ?? const RepeaterRoute.flood();
    // Null until the first login attempt reads the contact off the radio.
    final summary = known == null
        ? 'Route: -'
        : route.flood
            ? 'Flood (no route learned yet)'
            : route.direct
                ? 'Direct (no hops)'
                : route.hops.join(' > ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Icon(Icons.alt_route, size: 16, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              summary,
              style: TextStyle(
                  fontSize: 13,
                  fontFamily: route.hops.isEmpty ? null : 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (route.hops.isNotEmpty)
            TextButton(
              onPressed: () => _showRouteDetails(context, route),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Details'),
            ),
        ],
      ),
    );
  }

  void _showRouteDetails(BuildContext context, RepeaterRoute route) {
    final scheme = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Route to ${session.target.name}'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: route.hops.length,
            separatorBuilder: (_, __) => Divider(
                height: 1, color: scheme.outline.withValues(alpha: 0.3)),
            itemBuilder: (_, i) {
              final hex = route.hops[i];
              final name = session.hopName(hex);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  radius: 12,
                  backgroundColor: scheme.surfaceContainerHigh,
                  child: Text('${i + 1}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurface)),
                ),
                title: Text(name ?? 'Unknown repeater',
                    style: TextStyle(
                        fontSize: 14,
                        color: name == null ? scheme.onSurfaceVariant : null)),
                subtitle: Text(hex,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Cards: the settings pages' card, with an optional count on the right.
  // ---------------------------------------------------------------------

  Widget _card(BuildContext context, String title, List<Widget> children,
      {Widget? trailing, bool busy = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Progress sits on the card's top edge, so the card itself says
            // it is waiting on the mesh.
            SizedBox(
              height: 3,
              child: busy
                  ? const LinearProgressIndicator(minHeight: 3)
                  : const SizedBox.shrink(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.bold)),
                    ),
                    if (trailing != null) trailing,
                  ]),
                  const SizedBox(height: 8),
                  ...children,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The lock banner's tinted box, in the error colour, with a retry when
  /// the tap can simply be repeated.
  Widget _notice(BuildContext context, String text,
      {VoidCallback? onRetry, bool error = true}) {
    final scheme = Theme.of(context).colorScheme;
    final color = error ? scheme.error : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(error ? Icons.error_outline : Icons.info_outline,
                size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: TextStyle(fontSize: 13, color: color)),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                    foregroundColor: color,
                    visualDensity: VisualDensity.compact),
                child: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }

  /// The session's error, but only when [owner] is the tap that set it.
  Widget? _ownedError(_ErrorOwner owner, {VoidCallback? onRetry}) {
    final text = session.lastError;
    if (text == null || _errorOwner != owner) return null;
    return _notice(context, text, onRetry: onRetry);
  }

  // ---------------------------------------------------------------------
  // Log in
  // ---------------------------------------------------------------------

  Widget _loginCard(BuildContext context) {
    final busy = session.busy;
    // Only a failed session still has something to say. The session keeps
    // lastError across a later login, so without the state guard a mistyped
    // password would stay on screen under a session now logged in, and would
    // crowd out the guest sentence after a guest login.
    // No Retry inside the notice: the Log in button is right there.
    final loginError = session.state == RepeaterAdminState.failed
        ? _ownedError(_ErrorOwner.login)
        : null;
    return _card(context, 'Log in', busy: busy, [
      TextField(
        controller: _password,
        obscureText: !_showPassword,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        onSubmitted: busy ? null : (_) => _login(),
        decoration: InputDecoration(
          labelText: 'Admin password',
          isDense: true,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.lock_outline, size: 18),
          suffixIcon: IconButton(
            icon: Icon(
                _showPassword ? Icons.visibility_off : Icons.visibility,
                size: 18),
            tooltip: _showPassword ? 'Hide password' : 'Show password',
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text('Remember password', style: TextStyle(fontSize: 13)),
        value: _remember,
        onChanged: busy ? null : (v) => setState(() => _remember = v),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          if (_hasRemembered)
            TextButton(
                onPressed: busy ? null : _forget,
                child: const Text('Forget password')),
          const Spacer(),
          FilledButton.icon(
            onPressed: busy ? null : _login,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login, size: 18),
            label: Text(busy ? 'Logging in' : 'Log in'),
          ),
        ],
      ),
      // Notices land BELOW the buttons, so the field and Log in stay put
      // when one appears.
      if (session.state == RepeaterAdminState.guest)
        _notice(context,
            'That is the guest password. Claiming needs the admin password.',
            error: false),
      if (loginError case final w?) w,
    ]);
  }

  // ---------------------------------------------------------------------
  // Claim
  // ---------------------------------------------------------------------

  /// Who the claim listed: the signed-in account's name, else the entry the
  /// claim added to the repeater's administrators ([previousAdmins] is the
  /// list from before the tap), else the plain word.
  String _listedAs(String? displayName, List<String> previousAdmins) {
    if (displayName != null && displayName.isNotEmpty) return displayName;
    for (final name in _claimResult?.administrators ?? const <String>[]) {
      if (!previousAdmins.contains(name)) return name;
    }
    return 'you';
  }

  Widget _claimCard(BuildContext context, bool claimed, List<String> admins) {
    final appState = context.read<AppStateProvider>();
    final scheme = Theme.of(context).colorScheme;
    final busy = session.busy || _serverBusy;
    final listedAs = _listedAs(appState.portalAccount?.displayName, admins);
    final shown = _claimResult?.administrators ?? admins;
    final headline = claimed
        ? (_claimResult != null ? 'Claimed as $listedAs' : 'You administer this repeater')
        : 'Not claimed';
    final detail = claimed
        ? (shown.isNotEmpty ? shown.join(', ') : 'Listed on the map')
        : 'List yourself as an administrator on the map';
    // One row: the fact on the left, its one action on the right, nothing
    // stacked under it.
    // The headline shares its row with the button; the detail gets the
    // full width underneath so it never has to be cut short.
    return _card(context, 'Claim', busy: _serverBusy, [
      Row(
        children: [
          Icon(
            claimed ? Icons.verified_user : Icons.verified_user_outlined,
            size: 20,
            color: claimed ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(headline,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 10),
          claimed
              ? OutlinedButton(
                  onPressed: busy ? null : _unclaim,
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  child: const Text('Unclaim'))
              : FilledButton(
                  onPressed: busy ? null : _claim,
                  style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  child: const Text('Claim')),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(left: 28, top: 2),
        child: Text(detail,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ),
      if (_claimError != null) _notice(context, _claimError!),
    ]);
  }

  // ---------------------------------------------------------------------
  // Neighbours
  // ---------------------------------------------------------------------

  Widget _neighboursCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = session.busy || _serverBusy;
    final fetched = session.neighboursFetchedAt != null;
    final held = session.neighbours.length;
    final total = session.neighboursTotal;
    final inUse = _errorOwner == _ErrorOwner.neighbours;
    final uploaded = _uploadedStamp != null &&
        _uploadedStamp == session.neighboursFetchedAt &&
        _uploadedHeld == held;
    final canUpload =
        !busy && fetched && session.neighbours.isNotEmpty && !uploaded;

    return _card(
      context,
      'Neighbours',
      // One page per tap. The bar shows for the page in flight, first or next.
      busy: (session.busy && inUse) || _serverBusy,
      trailing: fetched
          ? Text('$held of $total',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))
          : null,
      [
        if (!fetched)
          Text(
            'Ask the repeater which radios it has heard directly, then '
            'upload the list so the map can show its proven neighbours.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        if (fetched && session.neighbours.isEmpty)
          Text('The repeater reports no neighbours.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        if (session.neighbours.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outline.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                for (var i = 0; i < session.neighbours.length; i++) ...[
                  if (i > 0)
                    Divider(
                        height: 1,
                        thickness: 1,
                        color: scheme.outline.withValues(alpha: 0.3)),
                  _neighbourRow(context, session.neighbours[i]),
                ],
              ],
            ),
          ),
        if (_ownedError(_ErrorOwner.neighbours) case final w?) w,
        if (_uploadResult != null && !_uploadResult!.ok)
          _notice(context, _uploadResult!.message ?? _uploadResult!.userMessage),
        if (uploaded)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Icon(Icons.cloud_done, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'Uploaded $held to MeshMapper'
                '${_uploadResult?.resolved != null ? ' (${_uploadResult!.resolved} matched)' : ''}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary),
              ),
            ]),
          ),
        if (fetched && session.neighbours.isNotEmpty) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: session.hasMoreNeighbours
                ? TextButton.icon(
                    onPressed: busy ? null : _loadMoreNeighbours,
                    icon: const Icon(Icons.expand_more, size: 18),
                    label: Text('Load more ($held of $total)'),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Text('All $held neighbours loaded',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
          ),
        ],
        const SizedBox(height: 6),
        // Before the first fetch there is one thing to do, so one wide
        // button. After it, the short labels share the row.
        if (!fetched)
          FilledButton.tonalIcon(
            onPressed: busy ? null : _fetchNeighbours,
            icon: const Icon(Icons.hub_outlined, size: 18),
            label: const Text('Fetch neighbours'),
          )
        else
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: busy ? null : _fetchNeighbours,
                  child: const Text('Fetch again'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: canUpload ? _upload : null,
                  icon: Icon(uploaded ? Icons.check : Icons.cloud_upload_outlined,
                      size: 18),
                  label: Text(uploaded
                      ? 'Uploaded'
                      : held > 0
                          ? 'Upload $held'
                          : 'Upload'),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _neighbourRow(BuildContext context, RepeaterNeighbour n) {
    final scheme = Theme.of(context).colorScheme;
    final known = n.name != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n.name ?? n.prefixHex.substring(0, 8),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFamily: known ? null : 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  known ? n.prefixHex.substring(0, 8) : 'Not on the map',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: known ? 'monospace' : null,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${n.snrDb >= 0 ? '+' : ''}${n.snrDb.toStringAsFixed(1)} dB',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: _snrColor(n.snrDb),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 56,
            child: Text(
              _ago(n.heardSecsAgo),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// The noise floor chart's meaning: green is comfortable, orange is
  /// marginal, red is a link that barely decodes.
  static Color _snrColor(double snr) {
    if (snr >= 5) return const Color(0xFF22C55E);
    if (snr >= 0) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  static String _ago(int secs) {
    if (secs < 60) return '${secs}s ago';
    if (secs < 3600) return '${secs ~/ 60}m ago';
    if (secs < 86400) return '${secs ~/ 3600}h ago';
    return '${secs ~/ 86400}d ago';
  }
}

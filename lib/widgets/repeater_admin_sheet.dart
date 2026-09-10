import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/repeater_admin/repeater_admin_api.dart';
import '../services/repeater_admin/repeater_admin_models.dart';
import '../services/repeater_admin/repeater_admin_session.dart';
import '../utils/debug_logger_io.dart';
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
  if (!context.mounted) return;
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
    backgroundColor: Theme.of(context).colorScheme.surface,
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
  RepeaterAdminResult? _claimResult;
  RepeaterAdminResult? _uploadResult;
  String? _claimError;
  bool _serverBusy = false;
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
      _hasRemembered = true;
    }
    if (ok) setState(() => _claimError = null);
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

  Future<void> _claim() async {
    final appState = context.read<AppStateProvider>();
    setState(() {
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
    setState(() => _serverBusy = true);
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
    setState(() => _serverBusy = true);
    final result = await appState.uploadRepeaterNeighbours();
    if (!mounted) return;
    setState(() {
      _serverBusy = false;
      _uploadResult = result;
    });
    if (result.ok) {
      AppToast.success(context,
          'Neighbours uploaded (${result.resolved ?? 0} resolved, ${result.unresolved ?? 0} unknown)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = context.select((AppStateProvider p) => p.repeaterAdminSession);
    if (live == null || session.closed) {
      return _disconnected(context);
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
        return ListView(
          controller: widget.scrollController,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _header(context, admins, claimed),
            const SizedBox(height: 12),
            _loginCard(context),
            if (session.isLoggedIn) ...[
              const SizedBox(height: 12),
              _routeCard(context),
            ],
            if (session.isAdmin) ...[
              const SizedBox(height: 12),
              _claimCard(context, claimed, admins),
              const SizedBox(height: 12),
              _neighboursCard(context),
            ],
          ],
        );
      },
    );
  }

  Widget _disconnected(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('The radio disconnected.'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );

  Widget _header(BuildContext context, List<String> admins, bool claimed) {
    final (label, color) = switch (session.state) {
      RepeaterAdminState.idle => ('Not logged in', Colors.grey),
      RepeaterAdminState.ensuringContact ||
      RepeaterAdminState.loggingIn =>
        ('Logging in', Colors.blue),
      RepeaterAdminState.admin => ('Admin', const Color(0xFF22C55E)),
      RepeaterAdminState.guest => ('Guest', Colors.orange),
      RepeaterAdminState.failed => ('Failed', Colors.red),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(session.target.name,
                  style: Theme.of(context).textTheme.titleLarge,
                  overflow: TextOverflow.ellipsis),
            ),
            _chip(label, color),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        Text(session.target.shortId,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        const SizedBox(height: 4),
        Text(admins.isEmpty
            ? 'No administrators listed yet'
            : 'Administrators: ${admins.join(', ')}'),
        if (claimed) const Text('You administer this repeater'),
      ],
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      );

  Widget _card(BuildContext context, String title, List<Widget> children) =>
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      );

  Widget _error(String text, {VoidCallback? onRetry}) => Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(color: Colors.red))),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      );

  /// The session's error, but only when [owner] is the tap that set it.
  Widget? _ownedError(_ErrorOwner owner, {VoidCallback? onRetry}) {
    final text = session.lastError;
    if (text == null || _errorOwner != owner) return null;
    return _error(text, onRetry: onRetry);
  }

  Widget _loginCard(BuildContext context) {
    final busy = session.busy;
    return _card(context, 'Log in', [
      TextField(
        controller: _password,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'Admin password', isDense: true),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Remember password'),
        value: _remember,
        onChanged: busy ? null : (v) => setState(() => _remember = v),
      ),
      Row(
        children: [
          if (_hasRemembered)
            TextButton(onPressed: busy ? null : _forget, child: const Text('Forget password')),
          const Spacer(),
          FilledButton(
            onPressed: busy ? null : _login,
            child: busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Log in'),
          ),
        ],
      ),
      if (session.state == RepeaterAdminState.guest && session.lastError == null)
        const Text('That is the guest password. Claiming needs the admin password.'),
      if (_ownedError(_ErrorOwner.login, onRetry: busy ? null : _login) case final w?) w,
    ]);
  }

  Widget _routeCard(BuildContext context) {
    Future<void> reset() async {
      setState(() => _errorOwner = _ErrorOwner.route);
      await session.resetRoute();
    }

    return _card(context, 'Route', [
      Text('Route: ${session.describeRoute()}'),
      if (_ownedError(_ErrorOwner.route) case final w?) w,
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: session.busy ? null : reset,
          child: const Text('Reset route'),
        ),
      ),
    ]);
  }

  Widget _claimCard(BuildContext context, bool claimed, List<String> admins) {
    final appState = context.read<AppStateProvider>();
    final busy = session.busy || _serverBusy;
    final listedAs = appState.portalAccount?.displayName ?? 'you';
    final shown = _claimResult?.administrators ?? admins;
    return _card(context, 'Claim', [
      if (_claimResult != null) ...[
        Text('Claimed. Listed as $listedAs'),
        if (shown.isNotEmpty) Text('Administrators: ${shown.join(', ')}'),
      ],
      if (_claimError != null) _error(_claimError!),
      Align(
        alignment: Alignment.centerRight,
        child: claimed
            ? OutlinedButton(onPressed: busy ? null : _unclaim, child: const Text('Unclaim'))
            : FilledButton(
                onPressed: busy ? null : _claim,
                child: const Text('I administer this repeater')),
      ),
    ]);
  }

  Widget _neighboursCard(BuildContext context) {
    final busy = session.busy || _serverBusy;
    final fetched = session.neighboursFetchedAt != null;
    final held = session.neighbours.length;
    final total = session.neighboursTotal;
    final inUse = _errorOwner == _ErrorOwner.neighbours;
    Future<void> fetch() async {
      setState(() => _errorOwner = _ErrorOwner.neighbours);
      await session.fetchNeighbours();
    }

    Future<void> loadMore() async {
      setState(() => _errorOwner = _ErrorOwner.neighbours);
      await session.loadMoreNeighbours();
    }

    return _card(context, 'Neighbours', [
      // One page per tap. The bar shows for the page in flight, first or next.
      if (session.busy && inUse) const LinearProgressIndicator(),
      if (fetched && session.neighbours.isEmpty)
        const Text('The repeater reports no neighbours.'),
      for (final n in session.neighbours)
        Row(
          children: [
            Expanded(
              child: Text(n.name ?? n.prefixHex,
                  style: TextStyle(fontFamily: n.name == null ? 'monospace' : null),
                  overflow: TextOverflow.ellipsis),
            ),
            Text('${n.snrDb.toStringAsFixed(1)} dB'),
            const SizedBox(width: 8),
            Text(_ago(n.heardSecsAgo)),
          ],
        ),
      if (_ownedError(_ErrorOwner.neighbours) case final w?) w,
      if (_uploadResult != null && !_uploadResult!.ok) _error(_uploadResult!.userMessage),
      if (fetched && session.neighbours.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: session.hasMoreNeighbours
              ? TextButton(
                  onPressed: busy ? null : loadMore,
                  child: Text('Load more ($held of $total)'),
                )
              : Text('All $held neighbours loaded',
                  style: Theme.of(context).textTheme.bodySmall),
        ),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FilledButton.tonal(
            onPressed: busy ? null : fetch,
            child: Text(fetched ? 'Fetch again' : 'Fetch neighbours'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: (busy || !fetched || session.neighbours.isEmpty) ? null : _upload,
            child: Text('Upload $held to MeshMapper'),
          ),
        ],
      ),
    ]);
  }

  static String _ago(int secs) {
    if (secs < 60) return '${secs}s ago';
    if (secs < 3600) return '${secs ~/ 60}m ago';
    if (secs < 86400) return '${secs ~/ 3600}h ago';
    return '${secs ~/ 86400}d ago';
  }
}

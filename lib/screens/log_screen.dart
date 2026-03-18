import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../models/repeater.dart';
import '../providers/app_state_provider.dart';
import '../widgets/repeater_id_chip.dart';

/// Log screen with two tabs: All Pings (unified TX+RX+DISC+TRC) and Errors
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _allPingsKey = GlobalKey<_AllPingsTabState>();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    // Auto-switch to Error tab when requested
    if (appState.requestErrorLogSwitch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabController.index != 1) {
          _tabController.animateTo(1); // Switch to Error tab
          setState(() {});
        }
        appState.clearErrorLogSwitchRequest();
      });
    }

    final totalPings = appState.txLogEntries.length +
        appState.rxLogEntries.length +
        appState.discLogEntries.length +
        appState.traceLogEntries.length;

    final errorCount = appState.errorLogEntries.length;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Logs', style: TextStyle(fontSize: 18)),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            padding: EdgeInsets.zero,
            onSelected: (value) {
              if (value == 'copy') _copyCurrentTabToCsv(context, appState);
              if (value == 'clear') _confirmClearLogs(context, appState);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'copy', child: Text('Copy CSV')),
              const PopupMenuItem(value: 'clear', child: Text('Clear all logs')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(32),
          child: TabBar(
            controller: _tabController,
            indicatorSize: TabBarIndicatorSize.tab,
            dividerHeight: 1,
            labelPadding: EdgeInsets.zero,
            tabs: [
              Tab(height: 32, text: 'All Pings${totalPings > 0 ? ' ($totalPings)' : ''}'),
              Tab(height: 32, text: 'Errors${errorCount > 0 ? ' ($errorCount)' : ''}'),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _AllPingsTab(
            key: _allPingsKey,
            allEntries: appState.unifiedPingLogEntries,
            repeaters: appState.repeaters,
            txCount: appState.txLogEntries.length,
            rxCount: appState.rxLogEntries.length,
            discCount: appState.discLogEntries.length,
            traceCount: appState.traceLogEntries.length,
          ),
          _ErrorLogTab(entries: appState.errorLogEntries),
        ],
      ),
    );
  }

  void _copyCurrentTabToCsv(BuildContext context, AppStateProvider appState) {
    if (_tabController.index == 0) {
      _copyAllPingsToCsv(context, appState);
    } else {
      _copyErrorLogToCsv(context, appState.errorLogEntries);
    }
  }

  void _copyAllPingsToCsv(BuildContext context, AppStateProvider appState) {
    // If a search filter is active, export only the filtered unified entries
    final tabState = _allPingsKey.currentState;
    final searchQuery = tabState?._searchQuery ?? '';
    if (searchQuery.isNotEmpty && tabState != null) {
      final filtered = tabState._filteredEntries;
      if (filtered.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No matching entries to copy'), duration: Duration(seconds: 2)),
        );
        return;
      }
      final buffer = StringBuffer();
      buffer.writeln('type,data');
      for (final entry in filtered) {
        buffer.writeln(entry.toCsv());
      }
      Clipboard.setData(ClipboardData(text: buffer.toString()));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${filtered.length} filtered entries copied to clipboard'), duration: const Duration(seconds: 2)),
      );
      return;
    }

    final tx = appState.txLogEntries;
    final rx = appState.rxLogEntries;
    final disc = appState.discLogEntries;
    final trace = appState.traceLogEntries;

    if (tx.isEmpty && rx.isEmpty && disc.isEmpty && trace.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No ping log entries to copy'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final buffer = StringBuffer();

    if (tx.isNotEmpty) {
      buffer.writeln('--- TX Log ---');
      buffer.writeln('timestamp,latitude,longitude,power,events');
      for (final entry in tx) {
        buffer.writeln(entry.toCsv());
      }
      buffer.writeln();
    }

    if (rx.isNotEmpty) {
      buffer.writeln('--- RX Log ---');
      buffer.writeln('timestamp,repeater_id,snr,rssi,path_length,header,latitude,longitude');
      for (final entry in rx) {
        buffer.writeln(entry.toCsv());
      }
      buffer.writeln();
    }

    if (disc.isNotEmpty) {
      buffer.writeln('--- DISC Log ---');
      buffer.writeln('timestamp,latitude,longitude,noisefloor,node_count,nodes');
      for (final entry in disc) {
        buffer.writeln(entry.toCsv());
      }
      buffer.writeln();
    }

    if (trace.isNotEmpty) {
      buffer.writeln('--- TRC Log ---');
      buffer.writeln('timestamp,target_repeater,local_snr,local_rssi,remote_snr,latitude,longitude,noisefloor,success');
      for (final entry in trace) {
        buffer.writeln(entry.toCsv());
      }
    }

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All ping logs copied to clipboard'), duration: Duration(seconds: 2)),
    );
  }

  void _copyErrorLogToCsv(BuildContext context, List<UserErrorEntry> entries) {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No error log entries to copy'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('timestamp,severity,message');
    for (final entry in entries) {
      buffer.writeln(entry.toCsv());
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Error log copied to clipboard'), duration: Duration(seconds: 2)),
    );
  }

  void _confirmClearLogs(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Logs?'),
        content: const Text('This will clear TX, RX, DISC, TRC, and error logs.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearLogs();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// All Pings Tab — unified chronological view with type filters
// =============================================================================

class _AllPingsTab extends StatefulWidget {
  final List<UnifiedPingLogEntry> allEntries;
  final List<Repeater> repeaters;
  final int txCount;
  final int rxCount;
  final int discCount;
  final int traceCount;

  const _AllPingsTab({
    super.key,
    required this.allEntries,
    required this.repeaters,
    required this.txCount,
    required this.rxCount,
    required this.discCount,
    required this.traceCount,
  });

  @override
  State<_AllPingsTab> createState() => _AllPingsTabState();
}

class _AllPingsTabState extends State<_AllPingsTab> {
  final Set<PingLogType> _activeFilters = {
    PingLogType.tx,
    PingLogType.rx,
    PingLogType.disc,
    PingLogType.trace,
  };

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  /// Current filtered entries (used by CSV export)
  List<UnifiedPingLogEntry> _filteredEntries = [];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleFilter(PingLogType type) {
    setState(() {
      if (_activeFilters.contains(type)) {
        // Don't allow deselecting the last filter
        if (_activeFilters.length > 1) {
          _activeFilters.remove(type);
        }
      } else {
        _activeFilters.add(type);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Repeater name resolution & search matching
  // ---------------------------------------------------------------------------

  /// Resolve a short repeater ID to known repeater names via prefix matching.
  static ({List<String> names, bool ambiguous}) _resolveRepeaterNames(
    String repeaterId, List<Repeater> repeaters,
  ) {
    final idLower = repeaterId.toLowerCase();
    final matches = repeaters
        .where((r) => r.hexId.toLowerCase().startsWith(idLower))
        .map((r) => r.name)
        .toList();
    return (names: matches, ambiguous: matches.length > 1);
  }

  /// Whether a hex ID has ambiguous name matches (maps to multiple repeaters).
  static bool _isAmbiguousId(String repeaterId, List<Repeater> repeaters) {
    return _resolveRepeaterNames(repeaterId, repeaters).ambiguous;
  }

  /// True if the query looks like a hex string (only 0-9, a-f).
  static bool _isHexQuery(String query) {
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(query);
  }

  /// Whether an entry matches the current search query.
  bool _matchesSearch(UnifiedPingLogEntry entry, List<Repeater> repeaters) {
    if (_searchQuery.isEmpty) return true;
    final query = _searchQuery.toLowerCase();

    switch (entry.type) {
      case PingLogType.tx:
        final tx = entry.asTx;
        for (final event in tx.events) {
          if (event.repeaterId.toLowerCase().startsWith(query)) return true;
          final resolved = _resolveRepeaterNames(event.repeaterId, repeaters);
          if (resolved.names.any((n) => n.toLowerCase().contains(query))) return true;
        }
        return false;
      case PingLogType.rx:
        final rx = entry.asRx;
        if (rx.repeaterId.toLowerCase().startsWith(query)) return true;
        final resolved = _resolveRepeaterNames(rx.repeaterId, repeaters);
        return resolved.names.any((n) => n.toLowerCase().contains(query));
      case PingLogType.disc:
        final disc = entry.asDisc;
        for (final node in disc.discoveredNodes) {
          if (node.repeaterId.toLowerCase().startsWith(query)) return true;
          if (node.pubkeyHex != null && node.pubkeyHex!.toLowerCase().startsWith(query)) return true;
          final resolved = _resolveRepeaterNames(node.repeaterId, repeaters);
          if (resolved.names.any((n) => n.toLowerCase().contains(query))) return true;
        }
        return false;
      case PingLogType.trace:
        final trace = entry.asTrace;
        if (trace.targetRepeaterId.toLowerCase().startsWith(query)) return true;
        final resolved = _resolveRepeaterNames(trace.targetRepeaterId, repeaters);
        return resolved.names.any((n) => n.toLowerCase().contains(query));
    }
  }

  /// Whether an entry should show the ambiguity indicator.
  /// Only shown when searching by name (non-hex query) and a repeater ID is ambiguous.
  bool _shouldShowAmbiguity(UnifiedPingLogEntry entry, List<Repeater> repeaters) {
    if (_searchQuery.isEmpty || _isHexQuery(_searchQuery)) return false;

    switch (entry.type) {
      case PingLogType.tx:
        return entry.asTx.events.any((e) => _isAmbiguousId(e.repeaterId, repeaters));
      case PingLogType.rx:
        return _isAmbiguousId(entry.asRx.repeaterId, repeaters);
      case PingLogType.disc:
        return entry.asDisc.discoveredNodes.any((n) => _isAmbiguousId(n.repeaterId, repeaters));
      case PingLogType.trace:
        return _isAmbiguousId(entry.asTrace.targetRepeaterId, repeaters);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.allEntries
        .where((e) => _activeFilters.contains(e.type))
        .where((e) => _matchesSearch(e, widget.repeaters))
        .toList();
    _filteredEntries = filtered;

    final hasEntries = widget.allEntries.isNotEmpty;
    final hasResults = filtered.isNotEmpty;

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: SizedBox(
            height: 36,
            child: TextField(
              controller: _searchController,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search by repeater name or ID',
                hintStyle: const TextStyle(fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 18),
                prefixIconConstraints: const BoxConstraints(minWidth: 36),
                suffixIcon: _searchQuery.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        child: const Icon(Icons.close, size: 18),
                      )
                    : null,
                suffixIconConstraints: const BoxConstraints(minWidth: 36),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                ),
              ),
              onChanged: (value) => setState(() => _searchQuery = value.trim()),
            ),
          ),
        ),
        // Filter segmented row
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
            ),
            clipBehavior: Clip.antiAlias,
            child: IntrinsicHeight(
              child: Row(
                children: [
                  _buildFilterSegment(PingLogType.tx, 'TX', widget.txCount, Colors.green, isFirst: true),
                  _segmentDivider(context),
                  _buildFilterSegment(PingLogType.rx, 'RX', widget.rxCount, Colors.blue),
                  _segmentDivider(context),
                  _buildFilterSegment(PingLogType.disc, 'DISC', widget.discCount, const Color(0xFF7B68EE)),
                  _segmentDivider(context),
                  _buildFilterSegment(PingLogType.trace, 'TRC', widget.traceCount, Colors.cyan, isLast: true),
                ],
              ),
            ),
          ),
        ),
        // List
        Expanded(
          child: !hasResults
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        hasEntries ? Icons.search_off : Icons.list_alt,
                        size: 48,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        hasEntries && _searchQuery.isNotEmpty
                            ? 'No results for \'$_searchQuery\''
                            : 'No pings logged yet',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final unified = filtered[index];
                    final showAmbiguity = _shouldShowAmbiguity(unified, widget.repeaters);
                    return switch (unified.type) {
                      PingLogType.tx => _buildTxCard(context, unified.asTx, showAmbiguity: showAmbiguity),
                      PingLogType.rx => _buildRxCard(context, unified.asRx, showAmbiguity: showAmbiguity),
                      PingLogType.disc => _buildDiscCard(context, unified.asDisc, showAmbiguity: showAmbiguity),
                      PingLogType.trace => _buildTraceCard(context, unified.asTrace, showAmbiguity: showAmbiguity),
                    };
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFilterSegment(PingLogType type, String label, int count, Color color, {bool isFirst = false, bool isLast = false}) {
    final active = _activeFilters.contains(type);
    return Expanded(
      child: GestureDetector(
        onTap: () => _toggleFilter(type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          color: active ? color.withValues(alpha: 0.12) : Colors.transparent,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? color : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 4),
                Container(
                  constraints: const BoxConstraints(minWidth: 18, minHeight: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: active ? color : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    count > 99 ? '99+' : count.toString(),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      height: 1.0,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static Widget _segmentDivider(BuildContext context) {
    return VerticalDivider(
      width: 1,
      thickness: 1,
      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
    );
  }

  // ---------------------------------------------------------------------------
  // Type badge
  // ---------------------------------------------------------------------------

  static Widget _buildTypeBadge(PingLogType type) {
    final (label, color) = switch (type) {
      PingLogType.tx => ('TX', Colors.green),
      PingLogType.rx => ('RX', Colors.blue),
      PingLogType.disc => ('DISC', const Color(0xFF7B68EE)),
      PingLogType.trace => ('TRC', Colors.cyan),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared chip builder
  // ---------------------------------------------------------------------------

  static Widget _buildChip(String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TX Card
  // ---------------------------------------------------------------------------

  Widget _buildTxCard(BuildContext context, TxLogEntry entry, {bool showAmbiguity = false}) {
    final appState = context.read<AppStateProvider>();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => appState.navigateToMapCoordinates(entry.latitude, entry.longitude),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCardHeader(context, PingLogType.tx, entry.timeString, entry.locationString, showAmbiguity: showAmbiguity),
              // Repeaters table
              if (entry.events.isNotEmpty) ...[
                const SizedBox(height: 10),
                _buildRepeaterTable(context, entry.events),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  'No repeaters heard',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRepeaterTable(BuildContext context, List<RxEvent> events) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                SizedBox(width: 60, child: _tableHeader(context, 'Node')),
                Expanded(child: _tableHeader(context, 'SNR', center: true)),
                Expanded(child: _tableHeader(context, 'RSSI', center: true)),
              ],
            ),
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          ...events.map((event) => _buildTxRepeaterRow(context, event)),
        ],
      ),
    );
  }

  Widget _buildTxRepeaterRow(BuildContext context, RxEvent event) {
    final snrColor = _snrColor(event.severity);
    final rssiColor = _rssiColor(event.rssi);
    return InkWell(
      onTap: () => RepeaterIdChip.showRepeaterPopup(context, event.repeaterId),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            RepeaterIdChip(repeaterId: event.repeaterId, fontSize: 14, width: 60),
            Expanded(child: Center(child: _buildChip(event.snr?.toStringAsFixed(1) ?? '-', snrColor))),
            Expanded(child: Center(child: _buildChip(event.rssi != null ? '${event.rssi}' : '-', rssiColor))),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // RX Card
  // ---------------------------------------------------------------------------

  Widget _buildRxCard(BuildContext context, RxLogEntry entry, {bool showAmbiguity = false}) {
    final appState = context.read<AppStateProvider>();
    final snrColor = _snrColor(entry.severity);
    final rssiColor = _rssiColor(entry.rssi);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => appState.navigateToMapCoordinates(entry.latitude, entry.longitude),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCardHeader(context, PingLogType.rx, entry.timeString, entry.locationString, showAmbiguity: showAmbiguity),
              const SizedBox(height: 10),
              // Repeater table (single row)
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(width: 60, child: _tableHeader(context, 'Node')),
                          Expanded(child: _tableHeader(context, 'SNR', center: true)),
                          Expanded(child: _tableHeader(context, 'RSSI', center: true)),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: Theme.of(context).dividerColor),
                    InkWell(
                      onTap: () => RepeaterIdChip.showRepeaterPopup(context, entry.repeaterId),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Row(
                          children: [
                            RepeaterIdChip(repeaterId: entry.repeaterId, fontSize: 14, width: 60),
                            Expanded(child: Center(child: _buildChip(entry.snr?.toStringAsFixed(1) ?? '-', snrColor))),
                            Expanded(child: Center(child: _buildChip(entry.rssi != null ? '${entry.rssi}' : '-', rssiColor))),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DISC Card
  // ---------------------------------------------------------------------------

  Widget _buildDiscCard(BuildContext context, DiscLogEntry entry, {bool showAmbiguity = false}) {
    final appState = context.read<AppStateProvider>();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => appState.navigateToMapCoordinates(entry.latitude, entry.longitude),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCardHeader(context, PingLogType.disc, entry.timeString, entry.locationString, showAmbiguity: showAmbiguity),
              // Nodes table
              if (entry.discoveredNodes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(width: 70, child: _tableHeader(context, 'Node')),
                            Expanded(child: _tableHeader(context, 'RX SNR', center: true)),
                            Expanded(child: _tableHeader(context, 'RX RSSI', center: true)),
                            Expanded(child: _tableHeader(context, 'TX SNR', center: true)),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: Theme.of(context).dividerColor),
                      ...entry.discoveredNodes.map((node) => _buildDiscNodeRow(context, node)),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  'No nodes discovered',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiscNodeRow(BuildContext context, DiscoveredNodeEntry node) {
    final rxSnrColor = _snrColorFromValue(node.localSnr);
    final rssiColor = _rssiColor(node.localRssi);
    Color txSnrColor;
    if (node.remoteSnr <= -1) {
      txSnrColor = Colors.red;
    } else if (node.remoteSnr <= 5) {
      txSnrColor = Colors.orange;
    } else {
      txSnrColor = Colors.green;
    }

    return InkWell(
      onTap: () => RepeaterIdChip.showRepeaterPopup(context, node.repeaterId, fullHexId: node.pubkeyHex),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 70,
              child: Row(
                children: [
                  Flexible(child: RepeaterIdChip(repeaterId: node.repeaterId, fontSize: 14)),
                  Text(
                    node.nodeTypeLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF7B68EE),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: Center(child: _buildChip(node.localSnr.toStringAsFixed(1), rxSnrColor))),
            Expanded(child: Center(child: _buildChip('${node.localRssi}', rssiColor))),
            Expanded(child: Center(child: _buildChip(node.remoteSnr.toStringAsFixed(1), txSnrColor))),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Trace Card
  // ---------------------------------------------------------------------------

  Widget _buildTraceCard(BuildContext context, TraceLogEntry entry, {bool showAmbiguity = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    final appState = context.read<AppStateProvider>();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => appState.navigateToMapCoordinates(entry.latitude, entry.longitude),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCardHeader(context, PingLogType.trace, entry.timeString, entry.locationString, showAmbiguity: showAmbiguity),
              // Results table
              if (entry.success) ...[
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(width: 70, child: _tableHeader(context, 'Node')),
                            Expanded(child: _tableHeader(context, 'RX SNR', center: true)),
                            Expanded(child: _tableHeader(context, 'RX RSSI', center: true)),
                            Expanded(child: _tableHeader(context, 'TX SNR', center: true)),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: Theme.of(context).dividerColor),
                      _buildTraceNodeRow(context, entry),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  'No response',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTraceNodeRow(BuildContext context, TraceLogEntry entry) {
    final rxSnrColor = _snrColorFromNullableValue(entry.localSnr);
    final rssiColor = _rssiColor(entry.localRssi);
    final txSnrColor = _snrColorFromNullableValue(entry.remoteSnr);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 70, child: RepeaterIdChip(repeaterId: entry.targetRepeaterId, fontSize: 14)),
          Expanded(child: Center(child: _buildChip(entry.localSnr?.toStringAsFixed(1) ?? '-', rxSnrColor))),
          Expanded(child: Center(child: _buildChip(entry.localRssi != null ? '${entry.localRssi}' : '-', rssiColor))),
          Expanded(child: Center(child: _buildChip(entry.remoteSnr?.toStringAsFixed(1) ?? '-', txSnrColor))),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

  static Widget _buildCardHeader(BuildContext context, PingLogType type, String timeString, String locationString, {bool showAmbiguity = false}) {
    return Row(
      children: [
        _buildTypeBadge(type),
        if (showAmbiguity) ...[
          const SizedBox(width: 2),
          Tooltip(
            message: 'Repeater ID matches multiple nodes',
            child: Icon(Icons.help_outline, size: 14, color: Colors.amber.shade700),
          ),
        ],
        const SizedBox(width: 6),
        Text(
          timeString,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const Spacer(),
        Icon(Icons.location_on, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 2),
        Text(
          locationString,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  static Widget _tableHeader(BuildContext context, String text, {bool center = false}) {
    return Text(
      text,
      textAlign: center ? TextAlign.center : TextAlign.left,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  static Color _snrColor(SnrSeverity? severity) {
    return switch (severity) {
      SnrSeverity.poor => Colors.red,
      SnrSeverity.fair => Colors.orange,
      SnrSeverity.good => Colors.green,
      null => Colors.grey,
    };
  }

  static Color _snrColorFromValue(double snr) {
    if (snr <= -1) return Colors.red;
    if (snr <= 5) return Colors.orange;
    return Colors.green;
  }

  static Color _snrColorFromNullableValue(double? snr) {
    if (snr == null) return Colors.grey;
    return _snrColorFromValue(snr);
  }

  static Color _rssiColor(int? rssi) {
    if (rssi == null) return Colors.grey;
    if (rssi >= -70) return Colors.green;
    if (rssi >= -100) return Colors.orange;
    return Colors.red;
  }
}

// =============================================================================
// Error Log Tab (unchanged)
// =============================================================================

class _ErrorLogTab extends StatelessWidget {
  final List<UserErrorEntry> entries;

  const _ErrorLogTab({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
            const SizedBox(height: 16),
            Text('No errors logged', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        // Most recent first
        final entry = entries[entries.length - 1 - index];
        return _buildErrorEntry(context, entry);
      },
    );
  }

  Widget _buildErrorEntry(BuildContext context, UserErrorEntry entry) {
    IconData icon;
    Color color;
    switch (entry.severity) {
      case ErrorSeverity.info:
        icon = Icons.info_outline;
        color = Colors.blue;
      case ErrorSeverity.warning:
        icon = Icons.warning_amber_outlined;
        color = Colors.orange;
      case ErrorSeverity.error:
        icon = Icons.error_outline;
        color = Colors.red;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(entry.message),
        subtitle: Text(
          entry.timeString,
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

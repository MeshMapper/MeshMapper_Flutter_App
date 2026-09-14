import 'package:flutter/material.dart';

import 'onboarding_guide_pages.dart';

enum OnboardingGuideResult { skipped, finished }

typedef OnboardingGuideCompletion = Future<bool> Function();

class OnboardingGuideScreen extends StatefulWidget {
  const OnboardingGuideScreen({
    super.key,
    this.complete,
  });

  final OnboardingGuideCompletion? complete;

  @override
  State<OnboardingGuideScreen> createState() => _OnboardingGuideScreenState();
}

class _OnboardingGuideScreenState extends State<OnboardingGuideScreen> {
  static const _pageCount = 12;
  final PageController _pageController = PageController();
  int _pageIndex = 0;
  bool _completionInFlight = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goBack() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _goForward() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _completeAndPop(OnboardingGuideResult result) async {
    if (_completionInFlight) return;
    final complete = widget.complete;
    if (complete == null) {
      Navigator.of(context).pop(result);
      return;
    }

    setState(() => _completionInFlight = true);
    final completed = await complete();
    if (!mounted) return;
    if (completed) {
      Navigator.of(context).pop(result);
    } else {
      setState(() => _completionInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = buildOnboardingGuidePages(context);
    final isLastPage = _pageIndex == _pageCount - 1;

    return PopScope(
      canPop: !_completionInFlight,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            onPressed:
                _completionInFlight ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
          title: Text(
            'Page ${_pageIndex + 1} of $_pageCount',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          centerTitle: true,
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(88, 48),
              ),
              onPressed: _completionInFlight
                  ? null
                  : () => _completeAndPop(OnboardingGuideResult.skipped),
              child: const Text('Skip Guide'),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Semantics(
                label: 'Guide progress, page ${_pageIndex + 1} of $_pageCount',
                child: LinearProgressIndicator(
                  value: (_pageIndex + 1) / _pageCount,
                  minHeight: 3,
                ),
              ),
              Expanded(
                child: AbsorbPointer(
                  absorbing: _completionInFlight,
                  child: ExcludeFocus(
                    excluding: _completionInFlight,
                    child: PageView(
                      controller: _pageController,
                      physics: _completionInFlight
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      onPageChanged: (value) =>
                          setState(() => _pageIndex = value),
                      children: pages,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    if (_pageIndex > 0)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(104, 48),
                        ),
                        onPressed: _completionInFlight ? null : _goBack,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Back'),
                      )
                    else
                      const SizedBox(width: 104),
                    const Spacer(),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(128, 48),
                      ),
                      onPressed: _completionInFlight
                          ? null
                          : isLastPage
                              ? () => _completeAndPop(
                                    OnboardingGuideResult.finished,
                                  )
                              : _goForward,
                      icon:
                          Icon(isLastPage ? Icons.check : Icons.arrow_forward),
                      iconAlignment: IconAlignment.end,
                      label: Text(isLastPage ? 'Finish Guide' : 'Next'),
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
}

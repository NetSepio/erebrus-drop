import 'package:flutter/material.dart';

import '../../ui/theme/drop_theme.dart';
import '../../ui/widgets/drop_widgets.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({required this.onComplete, super.key});

  final Future<void> Function() onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;
  bool _saving = false;

  static const List<_OnboardingSlide> _slides = [
    _OnboardingSlide(
      title: 'Create a private Drop Room',
      body: 'Share files and text on your local network.',
    ),
    _OnboardingSlide(
      title: 'Guests can join from browser',
      body: 'No app install required for nearby devices.',
    ),
    _OnboardingSlide(
      title: 'No cloud. No account.',
      body: 'Your data stays on your devices.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _slides.length - 1;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: AmbientGlow()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxHeight < 430 ||
                    constraints.maxWidth > constraints.maxHeight * 1.45;
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 16 : 22,
                    vertical: compact ? 10 : 22,
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        height: compact ? 36 : 48,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            style: compact
                                ? TextButton.styleFrom(
                                    minimumSize: const Size(64, 34),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                  )
                                : null,
                            onPressed: _saving ? null : _complete,
                            child: const Text('Skip'),
                          ),
                        ),
                      ),
                      Expanded(
                        child: PageView.builder(
                          controller: _controller,
                          itemCount: _slides.length,
                          onPageChanged: (page) => setState(() => _page = page),
                          itemBuilder: (context, index) {
                            return _SlideContent(slide: _slides[index]);
                          },
                        ),
                      ),
                      if (compact)
                        _CompactControls(
                          page: _page,
                          slideCount: _slides.length,
                          isLast: isLast,
                          saving: _saving,
                          onPressed: isLast ? _complete : _next,
                        )
                      else ...[
                        _PageDots(page: _page, slideCount: _slides.length),
                        const SizedBox(height: 18),
                        PrimaryButton(
                          label: isLast ? 'Start Dropping' : 'Next',
                          icon: isLast
                              ? Icons.check_rounded
                              : Icons.arrow_forward_rounded,
                          busy: _saving,
                          expand: false,
                          onPressed: _saving
                              ? null
                              : (isLast ? _complete : _next),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _next() async {
    await _controller.nextPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _complete() async {
    setState(() => _saving = true);
    await widget.onComplete();
  }
}

class _SlideContent extends StatelessWidget {
  const _SlideContent({required this.slide});

  final _OnboardingSlide slide;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxHeight < 260 ||
            constraints.maxWidth > constraints.maxHeight * 1.8;
        final logoSize = compact ? 68.0 : 92.0;
        final titleStyle =
            (compact
                    ? Theme.of(context).textTheme.headlineSmall
                    : Theme.of(context).textTheme.headlineMedium)
                ?.copyWith(fontWeight: FontWeight.w900);
        final bodyStyle = compact
            ? Theme.of(context).textTheme.bodyLarge
            : Theme.of(context).textTheme.titleMedium;

        final logo = _DropLogo(size: logoSize);
        final copy = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: compact
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Text(
              slide.title,
              textAlign: compact ? TextAlign.start : TextAlign.center,
              style: titleStyle,
            ),
            SizedBox(height: compact ? 8 : 12),
            Text(
              slide.body,
              textAlign: compact ? TextAlign.start : TextAlign.center,
              style: bodyStyle,
            ),
          ],
        );

        final content = compact
            ? Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  logo,
                  const SizedBox(width: 22),
                  Flexible(child: copy),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [logo, const SizedBox(height: 28), copy],
              );

        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8),
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DropLogo extends StatelessWidget {
  const _DropLogo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.26),
        boxShadow: [
          BoxShadow(
            color: DropTheme.orange.withValues(alpha: 0.28),
            blurRadius: size * 0.3,
            offset: Offset(0, size * 0.15),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        DropTheme.logoAsset,
        fit: BoxFit.cover,
        semanticLabel: 'Erebrus Drop logo',
      ),
    );
  }
}

class _CompactControls extends StatelessWidget {
  const _CompactControls({
    required this.page,
    required this.slideCount,
    required this.isLast,
    required this.saving,
    required this.onPressed,
  });

  final int page;
  final int slideCount;
  final bool isLast;
  final bool saving;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _PageDots(page: page, slideCount: slideCount),
        ),
        PrimaryButton(
          label: isLast ? 'Start Dropping' : 'Next',
          icon: isLast ? Icons.check_rounded : Icons.arrow_forward_rounded,
          busy: saving,
          expand: false,
          onPressed: saving ? null : onPressed,
        ),
      ],
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.page, required this.slideCount});

  final int page;
  final int slideCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        slideCount,
        (index) => AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: index == page ? 26 : 8,
          height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: index == page
                ? Theme.of(context).colorScheme.primary
                : DropTheme.faint,
          ),
        ),
      ),
    );
  }
}

class _OnboardingSlide {
  const _OnboardingSlide({required this.title, required this.body});

  final String title;
  final String body;
}

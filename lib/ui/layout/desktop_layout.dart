import '../../core/platform_capabilities.dart';

/// How wide the scrollable content column may grow on desktop.
enum DesktopContentLayout {
  /// Home, rooms, send, settings — phone-width column.
  standard,

  /// Library and other file-heavy views — wider but still bounded.
  library,
}

/// Breakpoints and width caps for desktop window layouts.
class DesktopLayout {
  DesktopLayout._();

  /// Switch bottom navigation to a side rail at this width and above.
  static const double railBreakpoint = 980;

  static const double standardMaxWidth = 920;
  static const double libraryMaxWidth = 1180;
  static const double horizontalPadding = 40;

  static bool useSideRail(double windowWidth) {
    return isDesktopPlatform && windowWidth >= railBreakpoint;
  }

  static double contentMaxWidth({
    required double windowWidth,
    DesktopContentLayout layout = DesktopContentLayout.standard,
  }) {
    final cap = switch (layout) {
      DesktopContentLayout.standard => standardMaxWidth,
      DesktopContentLayout.library => libraryMaxWidth,
    };
    final padded = windowWidth - horizontalPadding;
    if (padded <= 0) {
      return cap;
    }
    return padded < cap ? padded : cap;
  }
}
import '../../core/platform_capabilities.dart';

/// How wide the scrollable content column may grow on desktop.
enum DesktopContentLayout {
  /// Home, rooms, send, settings — phone-width column.
  standard,

  /// Library and other file-heavy views — wider but still bounded.
  library,

  /// Desktop workspaces that become a two-pane layout on large windows.
  workspace,
}

/// Breakpoints and width caps for desktop window layouts.
class DesktopLayout {
  DesktopLayout._();

  /// Switch bottom navigation to a side rail at this width and above.
  ///
  /// The desktop app opens at 880 logical pixels, so the breakpoint must keep
  /// the default window in its desktop navigation mode while still allowing
  /// narrow windows to fall back to the compact bottom bar.
  static const double railBreakpoint = 840;

  static const double standardMaxWidth = 920;
  static const double libraryMaxWidth = 1180;
  static const double workspaceMaxWidth = 1180;
  static const double splitPaneBreakpoint = 960;
  static const double horizontalPadding = 40;

  static bool useSideRail(double windowWidth) {
    return isDesktopPlatform && windowWidth >= railBreakpoint;
  }

  static bool useSplitPane(double contentWidth) {
    return isDesktopPlatform && contentWidth >= splitPaneBreakpoint;
  }

  static double contentMaxWidth({
    required double windowWidth,
    DesktopContentLayout layout = DesktopContentLayout.standard,
  }) {
    final cap = switch (layout) {
      DesktopContentLayout.standard => standardMaxWidth,
      DesktopContentLayout.library => libraryMaxWidth,
      DesktopContentLayout.workspace => workspaceMaxWidth,
    };
    final padded = windowWidth - horizontalPadding;
    if (padded <= 0) {
      return cap;
    }
    return padded < cap ? padded : cap;
  }
}

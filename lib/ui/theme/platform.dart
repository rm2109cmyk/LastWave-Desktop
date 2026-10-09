import 'dart:io';

/// Platform detection helpers for macOS-specific UI adaptations.
///
/// All macOS-only UI code gates behind these helpers so Windows and
/// Linux behavior remains completely unchanged.
///
/// Usage:
/// ```dart
/// import '../theme/platform.dart';
///
/// if (isMacOS) {
///   // macOS-specific behavior
/// }
/// ```

/// Whether the current platform is macOS.
final bool isMacOS = Platform.isMacOS;

/// Whether the current platform is Windows.
final bool isWindows = Platform.isWindows;

/// Whether the current platform is Linux.
final bool isLinux = Platform.isLinux;

/// Returns the macOS-appropriate keyboard modifier symbol.
///
/// On macOS: ⌘ (Command). On others: Ctrl.
String get modifierKey => isMacOS ? '⌘' : 'Ctrl';

/// Formats a keyboard shortcut label for the current platform.
///
/// Examples:
///   shortcutLabel('K')  → '⌘K' on macOS, 'Ctrl+K' on others
///   shortcutLabel('L')  → '⌘L' on macOS, 'Ctrl+L' on others
String shortcutLabel(String key) =>
    isMacOS ? '⌘$key' : 'Ctrl+$key';

/// Formats a compact keyboard shortcut (for badges / search box hints).
///
/// Examples:
///   shortcutBadge('K')  → '⌘K' on macOS, 'Ctrl K' on others
String shortcutBadge(String key) =>
    isMacOS ? '⌘$key' : 'Ctrl $key';

/// Traffic-light inset width on macOS.
///
/// When using `TitleBarStyle.hiddenInset`, the native traffic-light
/// buttons occupy approximately this width. Content should be offset
/// by at least this amount from the leading edge.
const double macOSTrafficLightWidth = 78.0;

/// macOS sidebar width (expanded). Apple Music uses ~240px; we use
/// 220px for a slightly more compact feel that matches LastWave's
/// density while feeling spacious enough for macOS.
const double macOSSidebarWidth = 220.0;

/// macOS sidebar collapsed width — icon-only column.
const double macOSSidebarCollapsedWidth = 0.0;

/// macOS toolbar height — matches the standard NSToolbar height
/// when the title bar is hidden with inset traffic lights.
const double macOSToolbarHeight = 52.0;

/// macOS player dock height — slightly taller than WinUI for breathing room.
const double macOSDockHeight = 80.0;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/theme/drop_theme.dart';
import 'desktop_mdns_service.dart';
import 'platform_capabilities.dart';

typedef DesktopQuitHandler = Future<void> Function();

class DesktopShell with WindowListener, TrayListener {
  DesktopShell._();

  static final DesktopShell instance = DesktopShell._();

  static bool _initialized = false;
  DesktopQuitHandler? _onQuit;

  static Future<void> ensureInitialized() async {
    if (!isDesktopPlatform || _initialized) {
      return;
    }
    await windowManager.ensureInitialized();
    await instance._configureWindow();
    await instance._configureTray();
    windowManager.addListener(instance);
    trayManager.addListener(instance);
    _initialized = true;
  }

  void registerQuitHandler(DesktopQuitHandler handler) {
    _onQuit = handler;
  }

  Future<void> hideToTray() async {
    if (!isDesktopPlatform) {
      return;
    }
    await windowManager.hide();
  }

  Future<void> showFromTray() async {
    if (!isDesktopPlatform) {
      return;
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    if (!isDesktopPlatform) {
      return;
    }
    final handler = _onQuit;
    if (handler != null) {
      await handler();
    }
    await DesktopMdnsService.instance.stopPublish();
    await trayManager.destroy();
    await windowManager.destroy();
    exit(0);
  }

  Future<void> _configureWindow() async {
    const options = WindowOptions(
      size: Size(880, 820),
      minimumSize: Size(720, 640),
      center: true,
      title: 'Erebrus Drop',
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    await windowManager.setPreventClose(true);
  }

  Future<void> _configureTray() async {
    if (Platform.isMacOS) {
      await trayManager.setIcon(
        DropTheme.trayIconTemplate,
        isTemplate: true,
        iconSize: 18,
      );
    } else {
      await trayManager.setIcon(DropTheme.trayIcon);
    }
    await trayManager.setToolTip('Erebrus Drop');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Show Erebrus Drop'),
          MenuItem(key: 'quit', label: 'Quit'),
        ],
      ),
    );
  }

  @override
  void onWindowClose() {
    unawaited(hideToTray());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showFromTray());
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showFromTray());
      case 'quit':
        unawaited(quit());
    }
  }
}
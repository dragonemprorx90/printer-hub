import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'moonraker.dart';
import 'settings.dart';

final _plugin = FlutterLocalNotificationsPlugin();
bool _ready = false;
int _nextId = 1;
final _watched = <String>{};

/// Native menu-bar item on macOS (see MainFlutterWindow.swift).
const _statusBar = MethodChannel('printerhub/statusbar');
final _barText = <String, String>{};
String? _lastBar;

Future<void> initNotifications() async {
  try {
    const darwin = DarwinInitializationSettings();
    await _plugin.initialize(
      settings: const InitializationSettings(
        macOS: darwin,
        iOS: darwin,
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _ready = true;
  } catch (_) {
    // Notifications are a nice-to-have; the app works without them.
  }
  _setBar('');
}

Future<void> notify(String title, String body) async {
  if (!_ready) return;
  await _plugin.show(
    id: _nextId++,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      macOS: DarwinNotificationDetails(),
      iOS: DarwinNotificationDetails(),
      android: AndroidNotificationDetails('prints', 'Print alerts',
          importance: Importance.high, priority: Priority.high),
    ),
  );
}

/// Mid-print alerts not yet sent for this print: 'first' once the second
/// layer starts, 'almost' once about 10 minutes are left. [sent] carries
/// what was already sent for the same file.
@visibleForTesting
Set<String> milestones({required String state, int? layer, double? eta, required Set<String> sent}) {
  if (state != 'printing') return const {};
  return {
    if (layer != null && layer >= 2 && !sent.contains('first')) 'first',
    if (eta != null && eta > 0 && eta <= 600 && !sent.contains('almost')) 'almost',
  };
}

/// Turns printer state changes into notifications and keeps the macOS
/// menu-bar status current. Safe to call repeatedly for the same printer.
///
/// ponytail: alerts fire while the app is running (or suspended in the
/// background on desktop). Push alerts with the app fully closed need a
/// server-side relay; add one only if that becomes a real need.
void watchPrinter(Printer p, MoonrakerClient c) {
  if (!_watched.add(p.key)) return;
  String? last, milestoneFile;
  var sent = <String>{};
  final humidityAlerted = <String, DateTime>{};
  c.stream.listen((s) {
    if (!s.online) return;
    final state = s.state, file = s.filename ?? '';
    if (file != milestoneFile) {
      milestoneFile = file;
      // Joining a print already past these points shouldn't alert.
      sent = {
        if ((s.currentLayer ?? 0) >= 2) 'first',
        if (s.eta != null && s.eta! <= 600) 'almost',
      };
    }
    for (final m in milestones(state: state, layer: s.currentLayer, eta: s.eta, sent: sent)) {
      sent.add(m);
      if (m == 'first' && settings.flag('notifyFirstLayer')) {
        notify('${p.name}: first layer done', 'Have a look before it goes on: $file');
      } else if (m == 'almost' && settings.flag('notifyAlmost')) {
        notify('${p.name}: almost done', 'About 10 minutes left on $file');
      }
    }
    if (last != null && state != last) {
      if ((state == 'complete' || state == 'error' || state == 'paused') &&
          settings.flag('feedback')) {
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
      }
      if (state == 'complete' && settings.flag('notifyDone')) {
        notify('${p.name}: print finished', file);
      } else if (state == 'error' && settings.flag('notifyError')) {
        notify('${p.name}: print failed', s.message ?? file);
      } else if (state == 'cancelled' && settings.flag('notifyError')) {
        notify('${p.name}: print cancelled', file);
      } else if (state == 'paused' &&
          last == 'printing' &&
          settings.flag('notifyPause')) {
        notify('${p.name}: print paused',
            s.message ?? 'Check the printer (filament run-out?)');
      }
    }
    last = state;

    if (settings.flag('notifyHumidity')) {
      final limit = settings.number('humidityLimit', 45);
      for (final b in s.cfs) {
        final h = b.humidity, prev = humidityAlerted[b.name];
        if (h == null || h < limit) continue;
        if (prev != null && DateTime.now().difference(prev).inHours < 6) continue;
        humidityAlerted[b.name] = DateTime.now();
        notify('${p.name} ${b.name}: humidity ${h.toStringAsFixed(0)}%',
            'Above your ${limit.toStringAsFixed(0)}% limit. Dry the filament.');
      }
    }

    final active = state == 'printing' || state == 'paused';
    if (active) {
      final eta = s.eta;
      _barText[p.key] =
          '${(s.progress * 100).round()}%${eta == null ? '' : ' · ${_short(eta)}'}';
    } else {
      _barText.remove(p.key);
    }
    _setBar(_barText.values.join('   '));
  });
}

String _short(double secs) {
  final d = Duration(seconds: secs.round());
  return d.inHours > 0
      ? '${d.inHours}h${(d.inMinutes % 60).toString().padLeft(2, '0')}'
      : '${d.inMinutes}m';
}

void _setBar(String text) {
  if (!Platform.isMacOS || text == _lastBar) return;
  _lastBar = text;
  _statusBar.invokeMethod('setTitle', text).catchError((_) => null);
}

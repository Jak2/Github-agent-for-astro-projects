// lib/system/device_metrics.dart
//
// This app's own CPU and RAM usage, read from /proc/self. No dependency, no
// platform channel. Everything here is pure Dart and the parsing is testable
// without touching the filesystem — feed it the raw text instead.
//
// Hard rule (design_theory.md): a failed read yields null, never a fabricated
// or stale number. The UI renders an em-dash for null.
import 'dart:async';
import 'dart:io';

/// Kernel clock ticks per second (USER_HZ). 100 on Android and on every
/// mainstream Linux build; the kernel exposes it via sysconf(_SC_CLK_TCK),
/// which Dart cannot call without FFI. If a device ever differs, CPU% is
/// scaled wrong by a constant factor — RAM is unaffected.
const int kUserHz = 100;

class DeviceSnapshot {
  /// Resident set size in kB, or null if /proc/self/status was unreadable.
  final int? rssKb;

  /// Process CPU use as a percentage of one wall-clock second. Null on the
  /// first sample (nothing to difference against) or on a failed read. May
  /// exceed 100 — this process has several threads.
  final double? cpuPercent;

  const DeviceSnapshot({this.rssKb, this.cpuPercent});
}

/// Pulls `VmRSS:    123456 kB` out of `/proc/<pid>/status`. Null if absent.
int? parseVmRssKb(String procStatus) {
  for (final line in procStatus.split('\n')) {
    if (!line.startsWith('VmRSS:')) continue;
    final digits = RegExp(r'\d+').firstMatch(line);
    return digits == null ? null : int.tryParse(digits.group(0)!);
  }
  return null;
}

/// utime + stime (fields 14 and 15, 1-indexed) from `/proc/<pid>/stat`, in
/// clock ticks. Field 2 is the executable name in parentheses and may itself
/// contain spaces and parens, so fields are counted from the *last* ')'.
int? parseCpuTicks(String procStat) {
  final close = procStat.lastIndexOf(')');
  if (close < 0) return null;
  // After ')' the next field is #3 (state), so utime is index 11, stime 12.
  final fields = procStat.substring(close + 1).trim().split(RegExp(r'\s+'));
  if (fields.length < 13) return null;
  final utime = int.tryParse(fields[11]);
  final stime = int.tryParse(fields[12]);
  if (utime == null || stime == null) return null;
  return utime + stime;
}

class DeviceMetrics {
  int? _lastTicks;
  int? _lastMillis;
  Timer? _timer;

  /// The testable core: given the raw /proc text and a wall clock reading,
  /// produce a snapshot and remember what the next call needs to difference
  /// against. Either text may be null (read failed).
  DeviceSnapshot update({
    required String? statusText,
    required String? statText,
    required int nowMillis,
  }) {
    final rssKb = statusText == null ? null : parseVmRssKb(statusText);
    final ticks = statText == null ? null : parseCpuTicks(statText);
    if (ticks == null) {
      // Do not keep a stale baseline — the next sample would divide a real
      // tick delta by a bogus interval.
      _lastTicks = null;
      _lastMillis = null;
      return DeviceSnapshot(rssKb: rssKb);
    }

    final prevTicks = _lastTicks;
    final prevMillis = _lastMillis;
    _lastTicks = ticks;
    _lastMillis = nowMillis;
    if (prevTicks == null || prevMillis == null) return DeviceSnapshot(rssKb: rssKb);

    final elapsedMillis = nowMillis - prevMillis;
    final deltaTicks = ticks - prevTicks;
    if (elapsedMillis <= 0 || deltaTicks < 0) return DeviceSnapshot(rssKb: rssKb);

    final cpuSeconds = deltaTicks / kUserHz;
    final percent = cpuSeconds / (elapsedMillis / 1000) * 100;
    return DeviceSnapshot(rssKb: rssKb, cpuPercent: percent);
  }

  /// One reading. Returns null only if neither figure could be read at all —
  /// e.g. a ROM that denies /proc/self, or a non-Linux host.
  Future<DeviceSnapshot?> sample() async {
    final status = await _readOrNull('/proc/self/status');
    final stat = await _readOrNull('/proc/self/stat');
    if (status == null && stat == null) return null;
    return update(
      statusText: status,
      statText: stat,
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<String?> _readOrNull(String path) async {
    try {
      return await File(path).readAsString();
    } catch (_) {
      // Expected on non-Linux hosts and on ROMs that restrict /proc. The
      // caller renders an em-dash; nothing is invented and nothing is hidden
      // beyond this one predictable case.
      return null;
    }
  }

  /// Polls until [stop]. [onSample] gets null when a reading is unavailable
  /// so the UI can blank itself rather than show the last good value.
  void start(void Function(DeviceSnapshot?) onSample,
      {Duration interval = const Duration(milliseconds: 1500)}) {
    stop();
    _timer = Timer.periodic(interval, (_) async => onSample(await sample()));
    // First reading immediately; it carries RAM but no CPU% yet.
    sample().then(onSample);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    // Drop the baseline: after a pause the next delta would span the gap.
    _lastTicks = null;
    _lastMillis = null;
  }
}

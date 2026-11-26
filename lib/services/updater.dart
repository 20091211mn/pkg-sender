import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'announcements.dart';
import 'config.dart';

export 'config.dart';

/// Bullet lines of release notes ("- feature", "* feature", "• feature").
/// Falls back to the non-empty lines when there are no bullets.
List<String> parseFeatures(String notes) {
  final lines = notes
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !RegExp(r'^Build \d+$').hasMatch(l))
      .toList();
  final bullets = lines
      .where((l) => l.startsWith('-') || l.startsWith('*') || l.startsWith('•'))
      .map((l) => l.replaceFirst(RegExp(r'^[-*•]\s*'), '').trim())
      .where((l) => l.isNotEmpty)
      .toList();
  return bullets.isNotEmpty ? bullets : lines;
}

class UpdateInfo {
  UpdateInfo({
    required this.tag,
    required this.build,
    required this.notes,
    required this.pageUrl,
    this.apkUrl,
    this.ipaUrl,
  });

  final String tag;
  final int build;
  String notes;
  final String pageUrl;
  final String? apkUrl;
  final String? ipaUrl;

  /// Why this build cannot be installed over the current app ("signature"), or null.
  String? blocked;

  List<String> get features => parseFeatures(notes);
}

/// What the native side found out about a downloaded APK.
class ApkCheck {
  ApkCheck({this.archiveVersion, this.installedVersion, this.sameSignature});

  final int? archiveVersion;
  final int? installedVersion;

  /// null = unknown (old Android versions cannot tell).
  final bool? sameSignature;
}

/// Result of the last update attempt, found at the next start.
class UpdateOutcome {
  UpdateOutcome(
      {required this.success, required this.tag, required this.features});

  final bool success;
  final String tag;
  final List<String> features;
}

class Updater {
  static const _ch = MethodChannel('ps4sender/updater');

  /// What the last check looked at (shown in Settings to explain a result).
  static String diagnostics = '';
  static String _source = '';

  static Future<String> _get(String url, {bool api = false}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(Uri.parse(url));
      if (api) req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'pkg-sender');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404) throw Exception('not_found');
      if (res.statusCode == 403 || res.statusCode == 429) {
        throw Exception(body.contains('rate limit') ? 'rate_limited' : 'HTTP ${res.statusCode}');
      }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      return body;
    } finally {
      c.close(force: true);
    }
  }

  /// The newest published version for this platform, or null when this build is
  /// already the latest. Throws when the check fails ("not_found" = private repo,
  /// "rate_limited" = too many requests from this network).
  static Future<UpdateInfo?> check() async {
    final best = Platform.isIOS ? await _latestIos() : await _latestAndroid();
    diagnostics =
        '$kRepo · ${best == null ? '-' : 'v${best.build}'} · build $kBuildNumber · $_source';
    if (best == null || best.build <= kBuildNumber) return null;
    await _attachNotes(best);
    await _attachBlocked(best);
    if (best.blocked == 'not_newer') return null; // the file is not newer: nothing to install
    return best;
  }

  /// Same as [check]; kept for the startup / notification refresh.
  static Future<UpdateInfo?> checkQuiet() => check();

  static Future<UpdateInfo?> _latestAndroid() async {
    // 1) A small file published by every build. It is not an API call, so it has
    //    no rate limit (the API allows only 60 requests/hour per network).
    try {
      final m = jsonDecode(await _get(
              'https://github.com/$kRepo/releases/download/app-meta/latest.json'))
          as Map<String, dynamic>;
      final build = (m['build'] as num).toInt();
      final apk = (m['apk'] ?? '') as String;
      if (build > 0 && apk.isNotEmpty) {
        _source = 'app-meta';
        return UpdateInfo(
          tag: (m['tag'] ?? 'v1.0.$build') as String,
          build: build,
          notes: ((m['notes'] ?? '') as String).trim(),
          pageUrl: (m['page'] ?? '') as String,
          apkUrl: apk,
        );
      }
    } catch (_) {}

    // 2) The releases API (older builds of the repository have no latest.json).
    _source = 'api';
    final list = jsonDecode(await _get(
        'https://api.github.com/repos/$kRepo/releases?per_page=15',
        api: true)) as List;
    UpdateInfo? best;
    for (final r in list) {
      final m = r as Map;
      if (m['draft'] == true || m['prerelease'] == true) continue;
      final tag = (m['tag_name'] ?? '') as String;
      final build = int.tryParse(tag.split('.').last) ?? 0;
      String? apk;
      String? other;
      for (final a in (m['assets'] as List? ?? const [])) {
        final name = ((a as Map)['name'] ?? '') as String;
        final url = (a['browser_download_url'] ?? '') as String;
        if (name == kApkName) apk = url;
        if (name.endsWith('.apk') && !name.toLowerCase().contains('admin')) {
          other = url; // e.g. the old "ps4-sender.apk"
        }
      }
      apk ??= other;
      if (apk == null || apk.isEmpty) continue; // release without an APK
      if (best == null || build > best.build) {
        best = UpdateInfo(
          tag: tag,
          build: build,
          notes: ((m['body'] ?? '') as String).trim(),
          pageUrl: (m['html_url'] ?? '') as String,
          apkUrl: apk,
        );
      }
    }
    return best;
  }

  /// On iPhone the version comes from the SideStore source (iOS builds only),
  /// not from the Android releases, which are published far more often.
  static Future<UpdateInfo?> _latestIos() async {
    _source = 'altstore';
    final j = jsonDecode(await _get(kSourceUrl)) as Map<String, dynamic>;
    final apps = j['apps'] as List? ?? const [];
    if (apps.isEmpty) return null;
    final app = apps.first as Map;
    final versions = app['versions'] as List? ?? const [];
    if (versions.isEmpty) return null;
    final v = versions.first as Map;
    final build = int.tryParse('${v['buildVersion'] ?? ''}') ?? 0;
    return UpdateInfo(
      tag: 'v${v['version'] ?? build}',
      build: build,
      notes: ((v['localizedDescription'] ?? '') as String).trim(),
      pageUrl: 'https://github.com/$kRepo/releases',
      ipaUrl: (v['downloadURL'] ?? '') as String,
    );
  }

  /// The "what's new" list comes from the admin's update notice for that build.
  static Future<void> _attachNotes(UpdateInfo u) async {
    if (u.notes.isNotEmpty && !RegExp(r'^Build \d+$').hasMatch(u.notes.trim())) return;
    try {
      for (final a in await AnnouncementService.fetch()) {
        if (a.type == 'update' && a.build == u.build && a.features.isNotEmpty) {
          u.notes = a.features.map((f) => '- $f').join('\n');
          return;
        }
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------- install

  /// Downloads the APK into the app cache and reports progress (0..1).
  static Future<String> download(
      String url, void Function(double progress) onProgress) async {
    final dir = await _ch.invokeMethod<String>('cacheDir');
    final file = File('$dir/update.apk');
    if (await file.exists()) await file.delete();
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await c.getUrl(Uri.parse(url)); // follows redirects
      final res = await req.close();
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength;
      var got = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress(got / total);
        }
      } finally {
        await sink.close();
      }
      return file.path;
    } finally {
      c.close(force: true);
    }
  }

  /// Compares the downloaded APK with the installed app (version and signature)
  /// so a doomed update is explained instead of failing silently.
  static Future<ApkCheck> inspect(String path) async {
    try {
      final m =
          await _ch.invokeMapMethod<String, dynamic>('inspect', {'path': path});
      if (m == null) return ApkCheck();
      return ApkCheck(
        archiveVersion: (m['archiveVersion'] as num?)?.toInt(),
        installedVersion: (m['installedVersion'] as num?)?.toInt(),
        sameSignature: m['sameSignature'] as bool?,
      );
    } catch (_) {
      return ApkCheck();
    }
  }

  /// Opens the system installer. Returns "started" or "needs_permission".
  static Future<String?> install(String path) =>
      _ch.invokeMethod<String>('install', {'path': path});

  // ------------------------------------------------------- update bookkeeping

  /// Remembers that the installer was opened for [u] (checked at the next start).
  static Future<void> markPending(UpdateInfo u) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('pending_build', u.build);
      await p.setInt('pending_time', DateTime.now().millisecondsSinceEpoch);
      await p.setString('pending_tag', u.tag);
      await p.setString('pending_notes', u.features.join('\n'));
    } catch (_) {}
  }

  /// Remembers that [build] cannot be installed over this app:
  /// "signature" (needs a reinstall) or "not_newer" (nothing to install).
  static Future<void> markBlocked(int build, String reason) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('blocked_build', build);
      await p.setString('blocked_reason', reason);
    } catch (_) {}
  }

  static Future<void> _attachBlocked(UpdateInfo u) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getInt('blocked_build') == u.build) {
        u.blocked = p.getString('blocked_reason');
      }
    } catch (_) {}
  }

  /// The reason [build] is blocked (null = not blocked). For the admin app.
  static Future<String?> blockedReason(int build) async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getInt('blocked_build') == build ? p.getString('blocked_reason') : null;
    } catch (_) {
      return null;
    }
  }

  /// Call once at startup: did the last update attempt work?
  /// A failed attempt is reported once and never hides the update.
  static Future<UpdateOutcome?> reconcile() async {
    try {
      final p = await SharedPreferences.getInstance();
      final pending = p.getInt('pending_build');
      if (pending == null) return null;
      final tag = p.getString('pending_tag') ?? 'v1.0.$pending';
      final notes = p.getString('pending_notes') ?? '';
      final age = DateTime.now().millisecondsSinceEpoch -
          (p.getInt('pending_time') ?? 0);
      if (kBuildNumber >= pending) {
        await _clearPending(p);
        if ((p.getInt('blocked_build') ?? 0) <= kBuildNumber) {
          await p.remove('blocked_build');
          await p.remove('blocked_reason');
        }
        return UpdateOutcome(
            success: true, tag: tag, features: parseFeatures(notes));
      }
      if (age > 60 * 1000) {
        await _clearPending(p);
        return UpdateOutcome(success: false, tag: tag, features: const []);
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _clearPending(SharedPreferences p) async {
    await p.remove('pending_build');
    await p.remove('pending_time');
    await p.remove('pending_tag');
    await p.remove('pending_notes');
  }
}

enum UpdateStep { done, needsPermission, blockedSignature, notNewer, failed }

class UpdateRun {
  UpdateRun(this.step, [this.error]);

  final UpdateStep step;
  final String? error;
}

/// Download, check and install an update. Used by the app and by the admin app.
class UpdateFlow {
  static Future<UpdateRun> run(
      UpdateInfo u, void Function(double progress) onProgress) async {
    final url = u.apkUrl;
    if (url == null) return UpdateRun(UpdateStep.failed, 'no APK');
    try {
      final path = await Updater.download(url, onProgress);
      final chk = await Updater.inspect(path);
      if (chk.sameSignature == false) {
        await Updater.markBlocked(u.build, 'signature');
        return UpdateRun(UpdateStep.blockedSignature);
      }
      final a = chk.archiveVersion;
      final i = chk.installedVersion;
      if (a != null && i != null && a <= i) {
        await Updater.markBlocked(u.build, 'not_newer');
        return UpdateRun(UpdateStep.notNewer);
      }
      final r = await Updater.install(path);
      if (r == 'needs_permission') return UpdateRun(UpdateStep.needsPermission);
      // Only now the installer is open; if the user cancels, the next start
      // reports it once but the update stays available.
      await Updater.markPending(u);
      return UpdateRun(UpdateStep.done);
    } catch (e) {
      return UpdateRun(UpdateStep.failed, '$e');
    }
  }
}

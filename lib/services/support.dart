import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// A conversation this phone started. The key proves ownership to the relay.
class LocalTicket {
  LocalTicket({required this.id, required this.key, required this.title, this.seen = 0});

  final int id;
  final String key;
  String title;

  /// How many messages the user has already seen (to show "new reply").
  int seen;

  factory LocalTicket.fromJson(Map<String, dynamic> j) => LocalTicket(
        id: (j['id'] as num).toInt(),
        key: j['key'] as String,
        title: (j['title'] ?? '') as String,
        seen: ((j['seen'] ?? 0) as num).toInt(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'key': key, 'title': title, 'seen': seen};
}

class SupportMessage {
  SupportMessage({required this.fromAdmin, required this.text, required this.date});

  final bool fromAdmin;
  final String text;
  final String date;
}

class SupportThread {
  SupportThread({required this.open, required this.title, required this.messages});

  final bool open;
  final String title;
  final List<SupportMessage> messages;
}

/// Talks to the support relay (see support/README.md).
class SupportService {
  static const _key = 'support_tickets';

  static bool get enabled => kSupportUrl.isNotEmpty;

  static Future<List<LocalTicket>> tickets() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => LocalTicket.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<LocalTicket> list) async {
    try {
      (await SharedPreferences.getInstance())
          .setString(_key, jsonEncode(list.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> _call(String method, String path,
      {Map<String, dynamic>? body}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await c.openUrl(method, Uri.parse('$kSupportUrl$path'));
      req.headers.set(HttpHeaders.userAgentHeader, 'pkg-sender');
      if (body != null) {
        final data = utf8.encode(jsonEncode(body));
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.contentLength = data.length;
        req.add(data);
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      Map<String, dynamic> j = {};
      try {
        j = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      if (res.statusCode != 200) throw Exception(j['error'] ?? 'HTTP ${res.statusCode}');
      return j;
    } finally {
      c.close(force: true);
    }
  }

  /// Sends a new message. Returns the saved ticket.
  static Future<LocalTicket> create({
    required String message,
    String contact = '',
    required String lang,
    required String app,
    required String version,
  }) async {
    final platform = Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other');
    final j = await _call('POST', '/ticket', body: {
      'message': message,
      'contact': contact,
      'app': app,
      'version': version,
      'platform': platform,
      'lang': lang,
    });
    final title = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    final t = LocalTicket(
      id: (j['id'] as num).toInt(),
      key: j['key'] as String,
      title: title.length > 60 ? title.substring(0, 60) : title,
    );
    final list = await tickets();
    list.insert(0, t);
    await save(list);
    return t;
  }

  static Future<SupportThread> fetch(LocalTicket t) async {
    final j = await _call('GET', '/ticket?id=${t.id}&key=${t.key}');
    return SupportThread(
      open: j['status'] == 'open',
      title: (j['title'] ?? '') as String,
      messages: ((j['messages'] as List?) ?? const [])
          .map((e) => SupportMessage(
                fromAdmin: (e as Map)['from'] == 'admin',
                text: (e['text'] ?? '') as String,
                date: (e['date'] ?? '') as String,
              ))
          .toList(),
    );
  }

  static Future<void> reply(LocalTicket t, String message) =>
      _call('POST', '/reply', body: {'id': t.id, 'key': t.key, 'message': message});

  /// Forget a ticket on this phone (the conversation stays in the support repository).
  static Future<void> forget(int id) async {
    final list = await tickets();
    list.removeWhere((e) => e.id == id);
    await save(list);
  }
}

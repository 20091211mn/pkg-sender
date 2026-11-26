import 'package:flutter/material.dart';

import '../services/store_catalog.dart';
import 'github_api.dart';

/// Numbers about the app, the store, the repository and the support inbox.
class StatsTab extends StatefulWidget {
  const StatsTab({
    super.key,
    required this.api,
    required this.items,
    required this.downloads,
    required this.supportRepo,
  });

  final GithubApi api;
  final List<StoreItem> items;
  final Map<String, int> downloads;
  final String supportRepo;

  @override
  State<StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<StatsTab> {
  AdminStats? _stats;
  List<Ticket>? _tickets;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await widget.api.stats();
      if (mounted) setState(() => _stats = s);
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذّر تحميل الإحصائيات: $e');
    }
    try {
      final t = await widget.api.listTickets(widget.supportRepo);
      if (mounted) setState(() => _tickets = t);
    } catch (_) {
      if (mounted) setState(() => _tickets = null);
    }
    if (mounted) setState(() => _loading = false);
  }

  int _downloadsOf(StoreItem i) {
    final name = GithubApi.assetNameOf(i.url);
    return name == null ? 0 : (widget.downloads[name] ?? 0);
  }

  Widget _row(String label, Object value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text('$value', style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      );

  Widget _card(String title, IconData icon, List<Widget> children) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
            ]),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _stats;
    final items = widget.items;
    final totalStore = items.fold<int>(0, (sum, i) => sum + _downloadsOf(i));
    final top = [...items]..sort((a, b) => _downloadsOf(b).compareTo(_downloadsOf(a)));
    final topShown = top.where((i) => _downloadsOf(i) > 0).take(5).toList();
    final maxTop = topShown.isEmpty ? 1 : _downloadsOf(topShown.first);
    final categories = {
      for (final i in items)
        if (i.category.isNotEmpty) i.category
    }.length;
    final t = _tickets;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
              ),
            ),
          if (s != null) ...[
            _card('التطبيق', Icons.phone_android, [
              _row('تنزيلات أندرويد (الإجمالي)', s.apkDownloads),
              _row('تنزيلات آخر إصدار', s.apkLatest),
              _row('تنزيلات الآيفون (IPA)', s.ipaDownloads),
              _row('تنزيلات تطبيق الإدارة', s.adminDownloads),
              _row('عدد الإصدارات المنشورة', s.releases),
            ]),
            _card('المتجر', Icons.storefront, [
              _row('عدد العناصر', items.length),
              _row('عدد التصنيفات', categories),
              _row('إجمالي طلبات التنزيل', totalStore),
              if (topShown.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('الأكثر طلباً', style: Theme.of(context).textTheme.labelLarge),
                for (final i in topShown)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: Text(i.title, overflow: TextOverflow.ellipsis)),
                          Text('${_downloadsOf(i)}'),
                        ]),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: _downloadsOf(i) / maxTop,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ],
                    ),
                  ),
              ],
            ]),
            _card('المستودع', Icons.hub_outlined, [
              _row('النجوم', s.stars),
              _row('المتابعون', s.watchers),
              _row('النسخ (Forks)', s.forks),
              _row('الزيارات آخر 14 يوماً', '${s.views} (${s.viewsUnique} زائر)'),
              _row('نسخ المستودع آخر 14 يوماً', '${s.clones} (${s.clonesUnique})'),
            ]),
          ],
          _card('الدعم', Icons.support_agent, [
            if (t == null)
              const Text('غير مفعّل، أو لا يوجد وصول للمستودع. راجع تبويب الدعم.')
            else ...[
              _row('محادثات مفتوحة', t.where((e) => e.open).length),
              _row('محادثات مغلقة', t.where((e) => !e.open).length),
              _row('المجموع', t.length),
            ],
          ]),
          const SizedBox(height: 4),
          Text(
            'الأرقام تقريبية: GitHub يحسب طلبات التنزيل، والتطبيق يحمّل الملفات على أجزاء.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

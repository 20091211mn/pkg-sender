import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/announcements.dart';
import '../services/store_catalog.dart';
import '../services/updater.dart';
import 'announcement_editor.dart';
import 'github_api.dart';
import 'item_editor.dart';
import 'stats_tab.dart';
import 'support_tab.dart';
import '../util/brand.dart';

void main() => runApp(const AdminApp());

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAdminName,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE08A1E),
          brightness: Brightness.dark,
        ),
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const AdminGate(),
    );
  }
}

/// Shows the login page until a valid token is saved.
class AdminGate extends StatefulWidget {
  const AdminGate({super.key});

  @override
  State<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGate> {
  GithubApi? _api;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final token = p.getString('admin_token');
      final repo = p.getString('admin_repo') ?? kRepo;
      if (token != null && token.isNotEmpty) {
        _api = GithubApi(token, repo);
        try {
          final full = await _api!.resolveRepo();
          if (full != repo) {
            await p.setString('admin_repo', full);
            _api = GithubApi(token, full);
          }
        } catch (_) {} // offline: keep the saved name
      }
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _logout() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('admin_token');
    if (mounted) setState(() => _api = null);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final api = _api;
    if (api == null) {
      return LoginPage(onLogin: (a) => setState(() => _api = a));
    }
    return AdminHome(api: api, onLogout: _logout);
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onLogin});

  final void Function(GithubApi api) onLogin;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _token = TextEditingController();
  final _repo = TextEditingController(text: kRepo);
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    final token = _token.text.trim();
    final repo = _repo.text.trim();
    if (token.isEmpty || !repo.contains('/')) {
      setState(() => _error = 'اكتب التوكن واسم المستودع بصيغة owner/name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = GithubApi(token, repo);
      await api.verify();
      final p = await SharedPreferences.getInstance();
      await p.setString('admin_token', token);
      await p.setString('admin_repo', repo);
      widget.onLogin(api);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is GithubError && e.status == 401
            ? 'التوكن غير صالح.'
            : 'فشل التحقق: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('إدارة المتجر')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
                'سجّل الدخول بتوكن GitHub (Personal access token) فيه صلاحية repo. يُحفظ على هذا الجوال فقط.'),
            const SizedBox(height: 16),
            TextField(
              controller: _token,
              obscureText: true,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'GitHub token',
                prefixIcon: Icon(Icons.key),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _repo,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'المستودع (owner/name)',
                prefixIcon: Icon(Icons.folder),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Card(
                color: cs.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
                ),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : _login,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.login),
              label: const Text('تسجيل الدخول'),
            ),
          ],
        ),
      ),
    );
  }
}

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.api, required this.onLogout});

  final GithubApi api;
  final VoidCallback onLogout;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int _tab = 0;

  List<StoreItem> _items = [];
  Map<String, int> _downloads = {};
  bool _loading = true;
  String? _error;

  List<Announcement> _notices = [];
  bool _noticesLoading = true;
  String? _noticesError;

  // updates of this admin app
  UpdateInfo? _upd;
  bool _updating = false;
  double _updProgress = 0;
  String? _updMsg;

  @override
  void initState() {
    super.initState();
    _load();
    _loadNotices();
    _reconcile();
    _checkAdminUpdate();
    _loadSupportRepo();
  }

  /// The private repository where the support conversations are stored.
  String _supportRepo = '';

  Future<void> _loadSupportRepo() async {
    String repo = '${widget.api.repo}-support';
    try {
      final p = await SharedPreferences.getInstance();
      repo = p.getString('support_repo') ?? repo;
    } catch (_) {}
    if (mounted) setState(() => _supportRepo = repo);
  }

  Future<void> _setSupportRepo(String repo) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('support_repo', repo);
    } catch (_) {}
    if (mounted) setState(() => _supportRepo = repo);
  }

  /// Did the last update of this app work?
  Future<void> _reconcile() async {
    final o = await Updater.reconcile();
    if (o == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(o.success ? 'تم تحديث تطبيق الإدارة' : 'لم يتم تثبيت التحديث'),
        content: Text(o.success
            ? 'أنت الآن على ${o.tag}.'
            : 'إذا ظهر تعارض في المثبّت فاحذف تطبيق الإدارة مرة واحدة ثم ثبّت النسخة الجديدة؛ بعدها تعمل التحديثات تلقائياً.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('حسناً')),
        ],
      ),
    );
  }

  Future<void> _checkAdminUpdate() async {
    try {
      final r = await widget.api.adminRelease();
      if (r == null || r.apkUrl == null || r.build <= kBuildNumber) return;
      final reason = await Updater.blockedReason(r.build);
      if (reason == 'not_newer') return;
      final u = UpdateInfo(
        tag: 'build ${r.build}',
        build: r.build,
        notes: '',
        pageUrl: '',
        apkUrl: r.apkUrl,
      );
      u.blocked = reason;
      if (mounted) {
        setState(() {
          _upd = u;
          if (reason == 'signature') _updMsg = _signatureMsg;
        });
      }
    } catch (_) {}
  }

  static const _signatureMsg =
      'لا يمكن التحديث فوق النسخة الحالية لأنها موقّعة بمفتاح مختلف. احذف تطبيق الإدارة مرة واحدة ثم ثبّت النسخة الجديدة؛ بعدها تعمل التحديثات تلقائياً.';

  Future<void> _updateApp() async {
    final u = _upd;
    if (u == null) return;
    setState(() {
      _updating = true;
      _updProgress = 0;
      _updMsg = null;
    });
    final run = await UpdateFlow.run(u, (p) {
      if (mounted) setState(() => _updProgress = p);
    });
    if (!mounted) return;
    setState(() {
      _updating = false;
      switch (run.step) {
        case UpdateStep.blockedSignature:
          u.blocked = 'signature';
          _updMsg = _signatureMsg;
          break;
        case UpdateStep.notNewer:
          _upd = null;
          _updMsg = 'النسخة المنزّلة ليست أحدث من المثبتة.';
          break;
        case UpdateStep.needsPermission:
          _updMsg =
              'اسمح بـ "تثبيت التطبيقات غير المعروفة" لهذا التطبيق ثم اضغط تحديث مرة أخرى.';
          break;
        case UpdateStep.failed:
          _updMsg = 'فشل التحديث: ${run.error}';
          break;
        case UpdateStep.done:
          _updMsg = null;
          break;
      }
    });
  }

  Widget _updateBanner(ColorScheme cs) {
    final u = _upd!;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.system_update),
              const SizedBox(width: 8),
              Expanded(child: Text('يوجد تحديث لتطبيق الإدارة (${u.tag})')),
              if (!_updating && u.blocked != 'signature')
                FilledButton(onPressed: _updateApp, child: const Text('تحديث')),
              if (!_updating && u.blocked == 'signature' && u.apkUrl != null)
                OutlinedButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: u.apkUrl!));
                    if (mounted) setState(() => _updMsg = 'تم نسخ رابط التنزيل.');
                  },
                  child: const Text('نسخ الرابط'),
                ),
            ]),
            if (_updating) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _updProgress),
              const SizedBox(height: 4),
              Text('${(_updProgress * 100).toStringAsFixed(0)}%'),
            ],
            if (_updMsg != null) ...[
              const SizedBox(height: 8),
              Text(_updMsg!),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.api.loadItems();
      Map<String, int> downloads = {};
      try {
        downloads = await widget.api.assetDownloads();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _items = items;
          _downloads = downloads;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذّر تحميل المتجر: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadNotices() async {
    setState(() {
      _noticesLoading = true;
      _noticesError = null;
    });
    try {
      final list = await widget.api.loadAnnouncements();
      if (mounted) setState(() => _notices = list);
    } catch (e) {
      if (mounted) setState(() => _noticesError = 'تعذّر تحميل الإشعارات: $e');
    } finally {
      if (mounted) setState(() => _noticesLoading = false);
    }
  }

  Future<void> _edit([StoreItem? item]) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ItemEditor(api: widget.api, item: item),
    ));
    if (changed == true) _load();
  }

  Future<void> _newNotice() async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => AnnouncementEditor(api: widget.api),
    ));
    if (changed == true) _loadNotices();
  }

  Future<bool> _confirm(String title, String text) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    return ok == true;
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _delete(StoreItem item) async {
    if (!await _confirm('حذف العنصر',
        'حذف "${item.title}" من المتجر؟ سيُحذف الملف المرفوع أيضاً إن كان على GitHub.')) {
      return;
    }
    try {
      await widget.api.removeItem(item);
      _load();
    } catch (e) {
      _snack('فشل الحذف: $e');
    }
  }

  Future<void> _deleteNotice(Announcement a) async {
    if (!await _confirm('حذف الإشعار', 'حذف "${a.title}"؟')) return;
    try {
      await widget.api.removeAnnouncement(a.id);
      _loadNotices();
    } catch (e) {
      _snack('فشل الحذف: $e');
    }
  }

  String _fmtSize(int b) {
    if (b <= 0) return '';
    const u = ['B', 'KB', 'MB', 'GB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
  }

  /// Download requests GitHub counted for the item's uploaded file (0 for external links).
  int _downloadsOf(StoreItem i) {
    final name = GithubApi.assetNameOf(i.url);
    return name == null ? 0 : (_downloads[name] ?? 0);
  }

  String _meta(StoreItem i) {
    final external = GithubApi.assetNameOf(i.url) == null;
    return [
      if (i.category.isNotEmpty) i.category,
      if (i.version.isNotEmpty) 'v${i.version}',
      if (_fmtSize(i.size).isNotEmpty) _fmtSize(i.size),
      if (i.history.isNotEmpty) '${i.history.length} إصدارات سابقة',
      external ? 'رابط خارجي' : '⬇ ${_downloadsOf(i)}',
    ].join(' · ');
  }

  Widget _centered(String text) => Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(text)),
      );

  Widget _storeTab(ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _centered(_error!);
    if (_items.isEmpty) {
      return _centered('المتجر فارغ. اضغط "إضافة" لنشر أول عنصر.');
    }
    final total = _items.fold<int>(0, (sum, i) => sum + _downloadsOf(i));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        if (total > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('إجمالي طلبات التنزيل (تقريبي): $total',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        for (final i in _items)
          Card(
            color: cs.surfaceContainerHigh,
            child: ListTile(
              leading: i.icon.isEmpty
                  ? const Icon(Icons.inventory_2, size: 40)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(i.icon,
                          width: 48,
                          height: 48,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.inventory_2)),
                    ),
              title: Row(children: [
                Expanded(child: Text(i.title)),
                if (i.featured) const Icon(Icons.star, size: 18),
              ]),
              subtitle: Text(_meta(i)),
              onTap: () => _edit(i),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(i),
              ),
            ),
          ),
      ],
    );
  }

  Widget _noticesTab(ColorScheme cs) {
    if (_noticesLoading) return const Center(child: CircularProgressIndicator());
    if (_noticesError != null) return _centered(_noticesError!);
    if (_notices.isEmpty) {
      return _centered('لا توجد إشعارات. اضغط "إشعار جديد" لنشر خبر أو تحديث.');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        for (final a in _notices)
          Card(
            color: cs.surfaceContainerHigh,
            child: ListTile(
              leading: Icon(a.type == 'update' ? Icons.new_releases : Icons.campaign),
              title: Text(a.title),
              subtitle: Text([
                if (a.date.length >= 10) a.date.substring(0, 10),
                if (a.features.isNotEmpty) '${a.features.length} ميزات',
                if (a.type == 'update') 'تحديث',
              ].join(' · ')),
              isThreeLine: false,
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteNotice(a),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const titles = ['إدارة المتجر', 'الإشعارات', 'الإحصائيات', 'الدعم'];
    final loading = _tab == 0 ? _loading : _noticesLoading;
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab]),
        actions: [
          if (_tab <= 1)
            IconButton(
                tooltip: 'تحديث',
                onPressed: loading ? null : (_tab == 0 ? _load : _loadNotices),
                icon: const Icon(Icons.refresh)),
          IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout)),
        ],
      ),
      floatingActionButton: _tab <= 1
          ? FloatingActionButton.extended(
              onPressed: _tab == 0 ? () => _edit() : _newNotice,
              icon: Icon(_tab == 0 ? Icons.add : Icons.add_alert),
              label: Text(_tab == 0 ? 'إضافة' : 'إشعار جديد'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.storefront_outlined),
              selectedIcon: Icon(Icons.storefront),
              label: 'المتجر'),
          NavigationDestination(
              icon: Icon(Icons.notifications_outlined),
              selectedIcon: Icon(Icons.notifications),
              label: 'الإشعارات'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'الإحصائيات'),
          NavigationDestination(
              icon: Icon(Icons.support_agent_outlined),
              selectedIcon: Icon(Icons.support_agent),
              label: 'الدعم'),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_upd != null) _updateBanner(cs),
            Expanded(child: _tabBody(cs)),
          ],
        ),
      ),
    );
  }

  Widget _tabBody(ColorScheme cs) {
    switch (_tab) {
      case 0:
        return _storeTab(cs);
      case 1:
        return _noticesTab(cs);
      case 2:
        return StatsTab(
          api: widget.api,
          items: _items,
          downloads: _downloads,
          supportRepo: _supportRepo,
        );
      default:
        return SupportTab(
          api: widget.api,
          repo: _supportRepo,
          onRepoChanged: _setSupportRepo,
        );
    }
  }
}

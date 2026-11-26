import 'package:flutter/material.dart';

import 'services/app_state.dart';
import 'services/config.dart';
import 'services/support.dart';
import 'util/brand.dart';

/// Help and support: write to the admin and read the answers.
class SupportPage extends StatefulWidget {
  const SupportPage({super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  List<LocalTicket> _tickets = [];
  final Map<int, SupportThread> _threads = {};
  bool _loading = true;

  String t(String en, String ar) => appArabic.value ? ar : en;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await SupportService.tickets();
    if (mounted) setState(() => _tickets = list);
    if (SupportService.enabled) {
      await Future.wait([
        for (final tk in list.take(15))
          SupportService.fetch(tk).then((th) {
            _threads[tk.id] = th;
          }).catchError((_) {}),
      ]);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _newTicket() async {
    final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const _NewTicketPage()));
    if (created == true) _load();
  }

  Future<void> _open(LocalTicket tk) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ThreadPage(ticket: tk),
    ));
    _load();
  }

  bool _hasNews(LocalTicket tk) {
    final th = _threads[tk.id];
    return th != null && th.messages.length > tk.seen && th.messages.last.fromAdmin;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: appArabic,
      builder: (context, ar, _) => Directionality(
        textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          appBar: AppBar(title: Text(t('Help and support', 'المساعدة والدعم'))),
          floatingActionButton: SupportService.enabled
              ? FloatingActionButton.extended(
                  onPressed: _newTicket,
                  icon: const Icon(Icons.edit),
                  label: Text(t('New message', 'رسالة جديدة')),
                )
              : null,
          body: SafeArea(
            child: !SupportService.enabled
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        t('Support is not enabled in this version yet.',
                            'خدمة الدعم غير مفعّلة في هذه النسخة بعد.'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                      children: [
                        Text(
                          t('Write to us about a problem or a question. Our answer appears here.',
                              'اكتب لنا عن مشكلة أو سؤال. يظهر ردّنا هنا.'),
                        ),
                        const SizedBox(height: 12),
                        if (_loading && _tickets.isEmpty)
                          const Center(child: Padding(
                            padding: EdgeInsets.all(24),
                            child: CircularProgressIndicator(),
                          ))
                        else if (_tickets.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(t('No messages yet.', 'لا توجد رسائل بعد.'),
                                textAlign: TextAlign.center),
                          )
                        else
                          for (final tk in _tickets)
                            Card(
                              color: cs.surfaceContainerHigh,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16)),
                              child: ListTile(
                                leading: const Icon(Icons.forum_outlined),
                                title: Text(tk.title,
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(() {
                                  final th = _threads[tk.id];
                                  if (th == null) return '#${tk.id}';
                                  return '#${tk.id} · ${th.open ? t('Open', 'مفتوحة') : t('Closed', 'مغلقة')} · ${th.messages.length} ${t('messages', 'رسائل')}';
                                }()),
                                trailing: _hasNews(tk)
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: cs.primary,
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(t('New reply', 'رد جديد'),
                                            style: TextStyle(
                                                color: cs.onPrimary, fontSize: 12)),
                                      )
                                    : const Icon(Icons.chevron_right),
                                onTap: () => _open(tk),
                              ),
                            ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _NewTicketPage extends StatefulWidget {
  const _NewTicketPage();

  @override
  State<_NewTicketPage> createState() => _NewTicketPageState();
}

class _NewTicketPageState extends State<_NewTicketPage> {
  final _message = TextEditingController();
  final _contact = TextEditingController();
  bool _busy = false;
  String? _error;

  String t(String en, String ar) => appArabic.value ? ar : en;

  @override
  void dispose() {
    _message.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final m = _message.text.trim();
    if (m.length < 5) {
      setState(() => _error = t('Write a few more words.', 'اكتب بضع كلمات أخرى.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SupportService.create(
        message: m,
        contact: _contact.text.trim(),
        lang: appArabic.value ? 'ar' : 'en',
        app: kAppName,
        version: kBuildNumber == 0 ? 'dev' : 'v1.0.$kBuildNumber',
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            t('Could not send the message ($e). Try again later.', 'تعذّر إرسال الرسالة ($e). حاول لاحقاً.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: appArabic,
      builder: (context, ar, _) => Directionality(
        textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          appBar: AppBar(title: Text(t('New message', 'رسالة جديدة'))),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _message,
                  enabled: !_busy,
                  minLines: 5,
                  maxLines: 10,
                  maxLength: 2000,
                  decoration: InputDecoration(
                    labelText: t('Your message', 'رسالتك'),
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contact,
                  enabled: !_busy,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: t('Contact (optional)', 'وسيلة تواصل (اختياري)'),
                    helperText: t('Email or Telegram, only if you want us to reach you outside the app.',
                        'بريد أو تيليجرام، فقط إن أردت أن نتواصل معك خارج التطبيق.'),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t('The message, the app version and the system type are sent to the developer. Nothing else.',
                      'تُرسل الرسالة ورقم إصدار التطبيق ونوع النظام إلى المطوّر. لا شيء آخر.'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: cs.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _send,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                  label: Text(t('Send', 'إرسال')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThreadPage extends StatefulWidget {
  const _ThreadPage({required this.ticket});

  final LocalTicket ticket;

  @override
  State<_ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<_ThreadPage> {
  SupportThread? _thread;
  final _reply = TextEditingController();
  bool _loading = true;
  bool _sending = false;
  String? _error;

  String t(String en, String ar) => appArabic.value ? ar : en;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final th = await SupportService.fetch(widget.ticket);
      // mark everything as seen
      final list = await SupportService.tickets();
      for (final tk in list) {
        if (tk.id == widget.ticket.id) tk.seen = th.messages.length;
      }
      await SupportService.save(list);
      if (mounted) setState(() => _thread = th);
    } catch (e) {
      if (mounted) setState(() => _error = t('Could not load the conversation ($e).', 'تعذّر تحميل المحادثة ($e).'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final m = _reply.text.trim();
    if (m.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await SupportService.reply(widget.ticket, m);
      _reply.clear();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = t('Could not send ($e).', 'تعذّر الإرسال ($e).'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: appArabic,
      builder: (context, ar, _) => Directionality(
        textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          appBar: AppBar(
            title: Text('#${widget.ticket.id}'),
            actions: [
              IconButton(
                tooltip: t('Refresh', 'تحديث'),
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _load,
              ),
              IconButton(
                tooltip: t('Remove from this phone', 'إزالة من هذا الجوال'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await SupportService.forget(widget.ticket.id);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: _loading && _thread == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            for (final m in _thread?.messages ?? const <SupportMessage>[])
                              Align(
                                alignment: m.fromAdmin
                                    ? AlignmentDirectional.centerStart
                                    : AlignmentDirectional.centerEnd,
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(12),
                                  constraints: BoxConstraints(
                                    maxWidth: MediaQuery.of(context).size.width * 0.8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: m.fromAdmin
                                        ? cs.surfaceContainerHighest
                                        : cs.primaryContainer,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        m.fromAdmin ? t('Support', 'الدعم') : t('You', 'أنت'),
                                        style: Theme.of(context).textTheme.labelSmall,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(m.text),
                                    ],
                                  ),
                                ),
                              ),
                            if (_thread != null && !_thread!.open)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  t('This conversation is closed. Write a reply to reopen it.',
                                      'هذه المحادثة مغلقة. اكتب رداً لإعادة فتحها.'),
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            if (_error != null)
                              Text(_error!, style: TextStyle(color: cs.error)),
                          ],
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _reply,
                        enabled: !_sending,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: t('Write a reply…', 'اكتب رداً…'),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

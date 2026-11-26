import 'package:flutter/material.dart';

import 'github_api.dart';

/// Inbox of the support conversations (issues of the private support repository).
class SupportTab extends StatefulWidget {
  const SupportTab({
    super.key,
    required this.api,
    required this.repo,
    required this.onRepoChanged,
  });

  final GithubApi api;
  final String repo;
  final void Function(String repo) onRepoChanged;

  @override
  State<SupportTab> createState() => _SupportTabState();
}

class _SupportTabState extends State<SupportTab> {
  List<Ticket> _tickets = [];
  bool _loading = true;
  bool _notFound = false;
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
      _notFound = false;
    });
    try {
      final list = await widget.api.listTickets(widget.repo);
      if (mounted) setState(() => _tickets = list);
    } on GithubError catch (e) {
      if (mounted) {
        setState(() {
          if (e.status == 404) {
            _notFound = true;
          } else {
            _error = 'تعذّر تحميل المحادثات: $e';
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذّر تحميل المحادثات: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editRepo() async {
    final c = TextEditingController(text: widget.repo);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مستودع الدعم'),
        content: TextField(
          controller: c,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
              labelText: 'owner/name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
        ],
      ),
    );
    final v = c.text.trim();
    c.dispose();
    if (ok == true && v.contains('/')) widget.onRepoChanged(v);
  }

  Future<void> _open(Ticket t) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TicketPage(api: widget.api, repo: widget.repo, ticket: t),
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            const Icon(Icons.lock_outline, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text(widget.repo, textDirection: TextDirection.ltr)),
            IconButton(
              tooltip: 'تغيير المستودع',
              icon: const Icon(Icons.edit),
              onPressed: _editRepo,
            ),
            IconButton(
              tooltip: 'تحديث',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _load,
            ),
          ]),
          if (_loading) const LinearProgressIndicator(),
          if (_notFound)
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'المستودع ${widget.repo} غير موجود أو ليس للتوكن صلاحية عليه.\n'
                  'أنشئه كمستودع خاص (gh repo create NAME --private) ثم اضغط تحديث. التفاصيل في ملف support/README.md.',
                  style: TextStyle(color: cs.onErrorContainer),
                ),
              ),
            ),
          if (_error != null)
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
              ),
            ),
          if (!_loading && !_notFound && _error == null && _tickets.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('لا توجد رسائل من المستخدمين بعد.', textAlign: TextAlign.center),
            ),
          for (final t in _tickets)
            Card(
              color: cs.surfaceContainerHigh,
              child: ListTile(
                leading: Icon(t.open ? Icons.mark_chat_unread_outlined : Icons.check_circle_outline),
                title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  '#${t.number}',
                  t.open ? 'مفتوحة' : 'مغلقة',
                  '${t.comments} ردود',
                  if (t.updated.length >= 10) t.updated.substring(0, 10),
                ].join(' · ')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(t),
              ),
            ),
        ],
      ),
    );
  }
}

class TicketPage extends StatefulWidget {
  const TicketPage({super.key, required this.api, required this.repo, required this.ticket});

  final GithubApi api;
  final String repo;
  final Ticket ticket;

  @override
  State<TicketPage> createState() => _TicketPageState();
}

class _TicketPageState extends State<TicketPage> {
  List<TicketMessage> _messages = [];
  final _reply = TextEditingController();
  late bool _open = widget.ticket.open;
  bool _loading = true;
  bool _sending = false;
  String? _error;

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
      final m = await widget.api.ticketThread(widget.repo, widget.ticket);
      if (mounted) setState(() => _messages = m);
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذّر تحميل المحادثة: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.api.replyTicket(widget.repo, widget.ticket.number, text);
      _reply.clear();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذّر الإرسال: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggle() async {
    try {
      await widget.api.setTicketOpen(widget.repo, widget.ticket.number, !_open);
      if (mounted) setState(() => _open = !_open);
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذّر تغيير الحالة: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = widget.ticket.meta;
    return Scaffold(
      appBar: AppBar(
        title: Text('#${widget.ticket.number}'),
        actions: [
          IconButton(
            tooltip: _open ? 'إغلاق المحادثة' : 'إعادة فتحها',
            icon: Icon(_open ? Icons.check_circle_outline : Icons.replay),
            onPressed: _toggle,
          ),
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loading && _messages.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (meta.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(meta,
                                textDirection: TextDirection.ltr,
                                style: Theme.of(context).textTheme.bodySmall),
                          ),
                        for (final m in _messages)
                          Align(
                            alignment: m.fromAdmin
                                ? AlignmentDirectional.centerEnd
                                : AlignmentDirectional.centerStart,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.8,
                              ),
                              decoration: BoxDecoration(
                                color: m.fromAdmin
                                    ? cs.primaryContainer
                                    : cs.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.fromAdmin ? 'أنت (الدعم)' : 'المستخدم',
                                      style: Theme.of(context).textTheme.labelSmall),
                                  const SizedBox(height: 2),
                                  Text(m.text),
                                ],
                              ),
                            ),
                          ),
                        if (_error != null) Text(_error!, style: TextStyle(color: cs.error)),
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
                      hintText: 'اكتب رداً…',
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
    );
  }
}

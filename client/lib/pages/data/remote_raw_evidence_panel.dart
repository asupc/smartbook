import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/sync_providers.dart';

class RemoteRawEvidencePanel extends ConsumerStatefulWidget {
  const RemoteRawEvidencePanel({super.key});
  @override
  ConsumerState<RemoteRawEvidencePanel> createState() =>
      _RemoteRawEvidencePanelState();
}

class _RemoteRawEvidencePanelState
    extends ConsumerState<RemoteRawEvidencePanel> {
  String? _source;
  int _page = 0, _total = 0, _request = 0, _detailRequest = 0;
  bool _loading = true, _busy = false, _detailLoading = false, _failed = false;
  List<SmartBookCloudRawEvidence> _items = [];
  SmartBookCloudRawEvidence? _detail;

  String copy(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  String date(DateTime value) => value.toLocal().toString().split('.').first;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final request = ++_request;
    ++_detailRequest;
    setState(() {
      _loading = true;
      _failed = false;
      _detail = null;
      _detailLoading = false;
      _items = [];
    });
    try {
      final remote = await ref.read(rawEvidenceRemoteStoreProvider.future);
      if (!mounted || request != _request) return;
      if (remote == null) {
        setState(() {
          _loading = false;
          _total = 0;
        });
        return;
      }
      final result = await remote.list(source: _source, offset: _page * 30);
      if (!mounted || request != _request) return;
      if (_page > 0 && result.items.isEmpty) {
        _page = 0;
        await _reload();
        return;
      }
      setState(() {
        _items = result.items;
        _total = result.total;
        _loading = false;
      });
    } catch (_) {
      if (mounted && request == _request)
        setState(() {
          _loading = false;
          _failed = true;
          _total = 0;
        });
    }
  }

  Future<void> _show(String id) async {
    final request = ++_detailRequest;
    final listRequest = _request;
    setState(() {
      _detail = null;
      _detailLoading = true;
      _failed = false;
    });
    try {
      final remote = ref.read(rawEvidenceRemoteStoreProvider).asData?.value;
      if (remote == null) return;
      final detail = await remote.get(id);
      if (mounted && request == _detailRequest && listRequest == _request)
        setState(() => _detail = detail);
    } catch (_) {
      if (mounted && request == _detailRequest && listRequest == _request)
        setState(() => _failed = true);
    } finally {
      if (mounted && request == _detailRequest && listRequest == _request)
        setState(() => _detailLoading = false);
    }
  }

  Future<void> _remove({String? id}) async {
    final remote = ref.read(rawEvidenceRemoteStoreProvider).asData?.value;
    if (remote == null || _busy) return;
    final source = _source;
    final before = DateTime.now();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(id == null
                  ? copy('清理服务端证据？', 'Clear server evidence?')
                  : copy('删除服务端证据？', 'Delete server evidence?')),
              content: Text(copy(
                  '仅删除当前账号的服务端证据（清理按当前来源，截止现在），不删除本机证据或交易。此操作不可恢复。',
                  'Only server evidence for this account is removed (cleanup uses the current source, up to now). Local evidence and transactions are kept. This cannot be undone.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(copy('取消', 'Cancel'))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(copy('确认删除', 'Confirm delete'))),
              ],
            ));
    if (!mounted ||
        confirmed != true ||
        remote != ref.read(rawEvidenceRemoteStoreProvider).asData?.value)
      return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      if (id == null) {
        await remote.cleanup(source: source, before: before);
      } else {
        await remote.delete(id);
      }
      if (mounted &&
          remote == ref.read(rawEvidenceRemoteStoreProvider).asData?.value)
        await _reload();
    } catch (_) {
      if (mounted &&
          remote == ref.read(rawEvidenceRemoteStoreProvider).asData?.value)
        setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rawEvidenceRemoteStoreProvider);
    ref.listen(rawEvidenceRemoteStoreProvider, (_, next) {
      _page = 0;
      _reload();
    });
    if (state.isLoading)
      return const Center(child: CircularProgressIndicator());
    if (state.hasError)
      return Text(copy('无法连接服务端，请检查云配置后重试。',
          'Cannot connect. Check your cloud configuration.'));
    if (state.asData?.value == null)
      return Text(copy('请先配置并登录 SmartBook Cloud。',
          'Configure and sign in to SmartBook Cloud first.'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(copy('服务端证据仅供查看；不会再次调用 AI 或自动记账。',
          'Viewing server evidence never calls AI or creates transactions.')),
      const SizedBox(height: 8),
      Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
                value: _source ?? '',
                items: [
                  DropdownMenuItem(
                      value: '', child: Text(copy('全部来源', 'All sources'))),
                  DropdownMenuItem(
                      value: 'sms', child: Text(copy('短信', 'SMS'))),
                  DropdownMenuItem(
                      value: 'notification',
                      child: Text(copy('通知', 'Notification'))),
                  DropdownMenuItem(
                      value: 'screenText',
                      child: Text(copy('屏幕文本', 'Screen text'))),
                  DropdownMenuItem(
                      value: 'screenshot',
                      child: Text(copy('截图', 'Screenshot'))),
                  DropdownMenuItem(
                      value: 'sharedImage',
                      child: Text(copy('分享图片', 'Shared image'))),
                  DropdownMenuItem(
                      value: 'deepLinkText',
                      child: Text(copy('链接文本', 'Deep-link text'))),
                ],
                onChanged: _busy
                    ? null
                    : (v) {
                        setState(() {
                          _source = v == '' ? null : v;
                          _page = 0;
                        });
                        _reload();
                      }),
            IconButton(
                tooltip: copy('刷新服务端', 'Refresh server'),
                onPressed: _busy ? null : _reload,
                icon: const Icon(Icons.refresh)),
            OutlinedButton.icon(
                onPressed:
                    _busy || _loading || _total == 0 ? null : () => _remove(),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(copy('清理服务端', 'Clear server'))),
          ]),
      if (_failed)
        Text(
            copy('操作失败或证据已过期，请刷新后重试。',
                'Request failed or evidence expired. Refresh and retry.'),
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      if (_loading || _busy || _detailLoading) const LinearProgressIndicator(),
      if (_detail case final detail?)
        Card(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(
                                copy('服务端原文详情', 'Server evidence detail'),
                                style:
                                    Theme.of(context).textTheme.titleMedium)),
                        IconButton(
                            onPressed: () {
                              ++_detailRequest;
                              setState(() => _detail = null);
                            },
                            icon: const Icon(Icons.close))
                      ]),
                      SelectableText([
                        detail.title,
                        detail.actor,
                        detail.sourceChannel,
                        date(detail.capturedAt),
                        if (detail.expiresAt != null)
                          '${copy("保留至", "Expires")} ${date(detail.expiresAt!)}',
                        detail.body,
                        const JsonEncoder.withIndent('  ')
                            .convert(detail.metadata)
                      ].whereType<String>().join('\n\n')),
                      TextButton.icon(
                          onPressed:
                              _busy ? null : () => _remove(id: detail.id),
                          icon: const Icon(Icons.delete_outline),
                          label: Text(copy('删除服务端记录', 'Delete server record'))),
                    ]))),
      if (!_loading && _items.isEmpty && !_failed)
        Padding(
            padding: const EdgeInsets.all(16),
            child: Text(copy('没有服务端证据。仅主动开启上传后采集的记录会上传。',
                'No server evidence. Only captures with server retention enabled are uploaded.'))),
      for (final item in _items)
        Card(
            child: ListTile(
          title:
              Text(item.title?.isNotEmpty == true ? item.title! : item.source),
          subtitle: Text(
              '${item.body ?? item.actor ?? ""}\n${date(item.capturedAt)}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _show(item.id),
        )),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(
            tooltip: copy('上一页', 'Previous page'),
            onPressed: _page == 0 || _loading || _busy
                ? null
                : () {
                    _page--;
                    _reload();
                  },
            icon: const Icon(Icons.chevron_left)),
        Text(copy('第 ${_page + 1} 页 · 共 $_total 条',
            'Page ${_page + 1} · $_total items')),
        IconButton(
            tooltip: copy('下一页', 'Next page'),
            onPressed: (_page + 1) * 30 >= _total || _loading || _busy
                ? null
                : () {
                    _page++;
                    _reload();
                  },
            icon: const Icon(Icons.chevron_right)),
      ]),
    ]);
  }
}

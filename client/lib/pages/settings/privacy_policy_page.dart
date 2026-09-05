import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/theme_providers.dart';
import '../../styles/tokens.dart';
import '../../utils/website_urls.dart';
import '../../widgets/ui/ui.dart';

/// 隐私政策 — 内嵌 WebView 打开官网 /privacy(embed 模式)。
///
/// 与帮助中心同款做法:embed 隐藏 navbar/footer 外链 chrome(审核风险)、
/// 域名白名单(外链转系统浏览器)、跟随 App 暗黑模式与主题色、加载失败兜底。
class PrivacyPolicyPage extends ConsumerStatefulWidget {
  const PrivacyPolicyPage({super.key});

  @override
  ConsumerState<PrivacyPolicyPage> createState() => _PrivacyPolicyPageState();
}

class _PrivacyPolicyPageState extends ConsumerState<PrivacyPolicyPage> {
  WebViewController? _controller;
  String _url = '';
  int _progress = 0;
  bool _failed = false;

  static String _hex(Color c) => [c.r, c.g, c.b]
      .map((v) => ((v * 255).round() & 0xff).toRadixString(16).padLeft(2, '0'))
      .join();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final locale = Localizations.localeOf(context);
    _url = WebsiteUrls.privacy(
      locale,
      dark: BeeTokens.isDark(context),
      primaryHex: _hex(ref.read(primaryColorProvider)),
    );
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(BeeTokens.scaffoldBackground(context))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageStarted: (_) {
          if (mounted) setState(() => _failed = false);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _progress = 100);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted) {
            setState(() => _failed = true);
          }
        },
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          final host = uri?.host ?? '';
          if (host.isEmpty || host.endsWith('beejz.com')) {
            return NavigationDecision.navigate;
          }
          launchUrl(Uri.parse(request.url),
              mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
      ))
      ..loadRequest(Uri.parse(_url));
    final platform = controller.platform;
    if (platform is WebKitWebViewController) {
      platform.setAllowsBackForwardNavigationGestures(true);
    }
    _controller = controller;
  }

  Future<void> _openInBrowser() async {
    final locale = Localizations.localeOf(context);
    final lang = locale.languageCode == 'zh' ? '' : '/en';
    await launchUrl(Uri.parse('${WebsiteUrls.baseUrl}$lang/privacy'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primary = ref.watch(primaryColorProvider);

    return PopScope(
      // iOS:单页隐私政策无 SPA 历史,直接放行退出;
      // Android:先在网页历史内回退,到底再退出路由。
      canPop: Platform.isIOS,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final controller = _controller;
        if (controller != null && await controller.canGoBack()) {
          await controller.goBack();
          return;
        }
        if (!context.mounted) return;
        Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: BeeTokens.scaffoldBackground(context),
        body: Column(
          children: [
            PrimaryHeader(
              title: l10n.aboutPrivacyPolicy,
              showBack: true,
              compact: true,
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(Localizations.localeOf(context).languageCode == 'zh'
                  ? 'SmartBook 原始证据隐私补充说明'
                  : 'SmartBook raw evidence privacy supplement'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(Localizations.localeOf(ctx).languageCode == 'zh' ? '原始证据 · 2026-09-05' : 'Raw evidence · 2026-09-05'),
                  content: SingleChildScrollView(child: Text(Localizations.localeOf(ctx).languageCode == 'zh'
                      ? '本机与服务端原始短信、通知和屏幕文本留存默认关闭，在隐私面板按来源分别开启并配置保留期。策略变更影响新采集事件，不追溯收集旧正文。\n\n仅服务端保存时，本机临时排队到上传成功或期限届满；上传成功清除临时原文。服务端证据按账号隔离，不随共享账本公开，不进入交易备注或普通同步。\n\n本机与服务端证据分别删除，不删除已生成的交易。查看不会再次调用 AI 或触发自动记账。本证据通道只支持文本和元数据，不支持截图原图。\n\nAI 授权、AI 调用记录、交易图片附件及备份是独立功能。关闭证据留存不等于停用 AI，也不清除这些独立记录。上游官网隐私页不包含本二开补充说明。'
                      : 'Local and server retention of original SMS, notifications and screen text is disabled by default. Configure each source in the privacy panel. Policy changes affect new captures only.\n\nServer-only retention uses a temporary local queue until upload succeeds or expires. Server evidence is private to your account, not shared with ledger members, and stays out of transaction notes and normal sync.\n\nDelete local and server evidence separately; transactions are kept. Viewing never invokes AI or bookkeeping. This channel supports text/metadata, not original screenshots.\n\nAI consent, AI call history, image attachments and backups are separate features. Disabling evidence retention does not disable AI or delete those records. The upstream website does not include this fork-specific supplement.')),
                  actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                ),
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  if (_controller != null && !_failed)
                    WebViewWidget(controller: _controller!),
                  if (_failed)
                    Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.wifi_off,
                              size: 48, color: BeeTokens.textTertiary(context)),
                          const SizedBox(height: 12),
                          Text(l10n.helpCenterLoadFailed,
                              style: TextStyle(
                                  color: BeeTokens.textSecondary(context))),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: primary),
                            onPressed: () {
                              setState(() => _failed = false);
                              _controller?.reload();
                            },
                            child: Text(l10n.helpCenterRetry,
                                style: const TextStyle(color: Colors.white)),
                          ),
                          TextButton(
                            onPressed: _openInBrowser,
                            child: Text(l10n.helpCenterOpenInBrowser,
                                style: TextStyle(color: primary)),
                          ),
                        ],
                      ),
                    ),
                  if (!_failed && _progress < 100)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                        value: _progress / 100,
                        minHeight: 2,
                        backgroundColor: Colors.transparent,
                        color: primary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../services/data/source_channel_resolver.dart';
import 'smartbook_icon.dart';

/// 自动识别 App 图标组件
///
/// 优先从 Android 原生 MethodChannel (`getAppIcon`) 获取设备安装的真实高清 App 图标；
/// 当原生不可用、加载中或非 Android 平台时，根据包名与渠道名回退到内置的 SVG/精美品牌图标。
class RecognitionAppIcon extends StatefulWidget {
  final String pkg;
  final double size;
  final double borderRadius;

  const RecognitionAppIcon({
    super.key,
    required this.pkg,
    this.size = 38,
    this.borderRadius = 8,
  });

  /// 内存静态缓存，避免在列表滚动中重复向原生请求相同的包名图标
  @visibleForTesting
  static final Map<String, Uint8List?> iconBytesCache = {};

  static final Set<String> _pendingRequests = {};
  static const _channel = MethodChannel('com.smartbook.zhi/screen_text');

  @override
  State<RecognitionAppIcon> createState() => _RecognitionAppIconState();
}

class _RecognitionAppIconState extends State<RecognitionAppIcon> {
  Uint8List? _iconBytes;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(covariant RecognitionAppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pkg != widget.pkg) {
      _loadIcon();
    }
  }

  void _loadIcon() {
    final pkg = _normalizePkg(widget.pkg);
    if (pkg.isEmpty || pkg == 'app') {
      _iconBytes = null;
      return;
    }

    if (RecognitionAppIcon.iconBytesCache.containsKey(pkg)) {
      _iconBytes = RecognitionAppIcon.iconBytesCache[pkg];
      return;
    }

    // 非 Android 或纯测试环境，直接使用 fallback
    if (!Platform.isAndroid) return;

    if (RecognitionAppIcon._pendingRequests.contains(pkg)) return;
    RecognitionAppIcon._pendingRequests.add(pkg);

    RecognitionAppIcon._channel
        .invokeMethod<Uint8List>('getAppIcon', {'pkg': pkg})
        .then((bytes) {
      RecognitionAppIcon.iconBytesCache[pkg] = bytes;
      RecognitionAppIcon._pendingRequests.remove(pkg);
      if (mounted && _normalizePkg(widget.pkg) == pkg) {
        setState(() {
          _iconBytes = bytes;
        });
      }
    }).catchError((_) {
      RecognitionAppIcon.iconBytesCache[pkg] = null;
      RecognitionAppIcon._pendingRequests.remove(pkg);
    });
  }

  static String _normalizePkg(String raw) {
    return raw.trim();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final r = widget.borderRadius;

    if (_iconBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Image.memory(
          _iconBytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildFallback(context),
        ),
      );
    }

    return _buildFallback(context);
  }

  Widget _buildFallback(BuildContext context) {
    final size = widget.size;
    final r = widget.borderRadius;
    final pkg = _normalizePkg(widget.pkg);
    final channel = SourceChannelResolver.channelForPackage(pkg);

    // 1. 自身应用 (智记 / SmartBook / app)
    if (pkg == 'app' || pkg.contains('smartbook')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: SmartBookIcon(size: size),
      );
    }

    // 2. 微信 (com.tencent.mm)
    if (pkg.contains('tencent.mm') || channel == '微信') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF07C160),
          borderRadius: BorderRadius.circular(r),
        ),
        padding: EdgeInsets.all(size * 0.15),
        child: SvgPicture.asset(
          'assets/icons/wechat.svg',
          fit: BoxFit.contain,
        ),
      );
    }

    // 3. 支付宝 (com.eg.android.AlipayGphone)
    if (pkg.contains('AlipayGphone') || channel == '支付宝') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF1677FF),
          borderRadius: BorderRadius.circular(r),
        ),
        padding: EdgeInsets.all(size * 0.15),
        child: SvgPicture.asset(
          'assets/icons/alipay.svg',
          fit: BoxFit.contain,
        ),
      );
    }

    // 4. 抖音 (com.ss.android.ugc.aweme)
    if (pkg.contains('aweme') || channel == '抖音') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF161823),
          borderRadius: BorderRadius.circular(r),
        ),
        padding: EdgeInsets.all(size * 0.15),
        child: SvgPicture.asset(
          'assets/icons/social/douyin.svg',
          fit: BoxFit.contain,
        ),
      );
    }

    // 5. 京东 (com.jingdong.app.mall)
    if (pkg.contains('jingdong') || channel == '京东') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFE2231A),
          borderRadius: BorderRadius.circular(r),
        ),
        child: Center(
          child: Text(
            'JD',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: size * 0.42,
              letterSpacing: -0.5,
            ),
          ),
        ),
      );
    }

    // 6. 云闪付 / 银联 (com.unionpay)
    if (pkg.contains('unionpay') || channel == '云闪付') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFE60012), Color(0xFF003087)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(r),
        ),
        child: Icon(
          Icons.credit_card,
          color: Colors.white,
          size: size * 0.55,
        ),
      );
    }

    // 7. 银行类 (cmb.pb, bank 等)
    if (pkg.contains('cmb.') ||
        pkg.contains('bank') ||
        (channel != null && channel.contains('银行'))) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFC8102E),
          borderRadius: BorderRadius.circular(r),
        ),
        padding: EdgeInsets.all(size * 0.18),
        child: SvgPicture.asset(
          'assets/icons/bank_card.svg',
          fit: BoxFit.contain,
          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        ),
      );
    }

    // 8. 美团
    if (pkg.contains('meituan') || channel == '美团') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFFFC300),
          borderRadius: BorderRadius.circular(r),
        ),
        child: Icon(
          Icons.shopping_bag,
          color: const Color(0xFF222222),
          size: size * 0.55,
        ),
      );
    }

    // 9. 默认兜底
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(r),
      ),
      child: Icon(
        Icons.apps_rounded,
        color: theme.colorScheme.primary,
        size: size * 0.55,
      ),
    );
  }
}

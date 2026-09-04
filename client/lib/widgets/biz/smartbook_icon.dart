import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class SmartBookIcon extends StatelessWidget {
  final double size;

  const SmartBookIcon({super.key, this.size = 256});

  @override
  Widget build(BuildContext context) {
    // 图标自带深蓝底色,深浅背景均可直接展示(无需 currentColor/暗黑遮罩)
    return SvgPicture.asset(
      'assets/icon/smartbook_icon.svg',
      width: size,
      height: size,
    );
  }
}

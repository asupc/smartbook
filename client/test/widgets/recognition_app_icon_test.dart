import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartbook/widgets/biz/recognition_app_icon.dart';

void main() {
  setUp(() {
    RecognitionAppIcon.iconBytesCache.clear();
  });

  group('RecognitionAppIcon', () {
    testWidgets('renders WeChat fallback correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecognitionAppIcon(
              pkg: 'com.tencent.mm',
              size: 40,
            ),
          ),
        ),
      );

      expect(find.byType(RecognitionAppIcon), findsOneWidget);
      expect(find.byType(Container), findsWidgets);
    });

    testWidgets('renders Alipay fallback correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecognitionAppIcon(
              pkg: 'com.eg.android.AlipayGphone',
              size: 40,
            ),
          ),
        ),
      );

      expect(find.byType(RecognitionAppIcon), findsOneWidget);
    });

    testWidgets('renders Douyin fallback correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecognitionAppIcon(
              pkg: 'com.ss.android.ugc.aweme',
              size: 40,
            ),
          ),
        ),
      );

      expect(find.byType(RecognitionAppIcon), findsOneWidget);
    });

    testWidgets('renders JD fallback with brand text correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecognitionAppIcon(
              pkg: 'com.jingdong.app.mall',
              size: 40,
            ),
          ),
        ),
      );

      expect(find.byType(RecognitionAppIcon), findsOneWidget);
      expect(find.text('JD'), findsOneWidget);
    });

    testWidgets('renders Bank fallback correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecognitionAppIcon(
              pkg: 'cmb.pb',
              size: 40,
            ),
          ),
        ),
      );

      expect(find.byType(RecognitionAppIcon), findsOneWidget);
    });

    testWidgets('renders SmartBook/app fallback correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecognitionAppIcon(
              pkg: 'app',
              size: 40,
            ),
          ),
        ),
      );

      expect(find.byType(RecognitionAppIcon), findsOneWidget);
    });

    testWidgets('renders default fallback for unknown package', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecognitionAppIcon(
              pkg: 'com.unknown.app',
              size: 40,
            ),
          ),
        ),
      );

      expect(find.byType(RecognitionAppIcon), findsOneWidget);
      expect(find.byIcon(Icons.apps_rounded), findsOneWidget);
    });

    testWidgets('renders memory image when cache is populated', (tester) async {
      // 1x1 transparent PNG bytes
      final dummyPng = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
      ]);

      RecognitionAppIcon.iconBytesCache['com.custom.cached'] = dummyPng;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecognitionAppIcon(
              pkg: 'com.custom.cached',
              size: 40,
            ),
          ),
        ),
      );

      expect(find.byType(Image), findsOneWidget);
    });
  });
}

/// 对抗性测试:金额编辑器(AmountEditorSheet)交互边界。
///
/// 攻击点:零/负金额、超长数字(U-1:位数上限 + 提交前 isFinite)、
/// 多点号、超精度、双击提交防重、运算模式(等号语义/除零,可测性 1 修复后
/// 经 Key 锚点可达)、窄屏与大字体。
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/providers/database_providers.dart';
import 'package:smartbook/widgets/biz/amount_editor_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late LocalRepository repo;

  setUp(() async {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  });

  tearDown(() async => db.close());

  Ledger cnyLedger() => Ledger(
        id: 1,
        name: 'L',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        myRole: 'owner',
        memberCount: 1,
        isShared: false,
        monthStartDay: 1,
      );

  Widget host({
    double? initialAmount,
    AmountEditorSubmit? onSubmit,
    bool allowSaveAndContinue = false,
  }) {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        currentLedgerProvider
            .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: AmountEditorSheet(
            categoryName: '餐饮',
            initialDate: DateTime(2026, 7, 12),
            initialAmount: initialAmount,
            ledgerId: 1,
            allowSaveAndContinue: allowSaveAndContinue,
            onSubmit: onSubmit ?? (_) {},
          ),
        ),
      ),
    );
  }

  Future<void> tapKey(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(InkWell, label).first,
        warnIfMissed: false);
    await tester.pump();
  }

  Future<void> typeDigits(WidgetTester tester, String digits) async {
    for (final ch in digits.split('')) {
      await tapKey(tester, ch);
    }
  }

  /// 运算符键的测试锚点(U-1/可测性 1):键上的标签是 Text.rich(「+ / ×」),
  /// `find.widgetWithText` 按 Text.data 匹配不到;Key 由产品代码提供,
  /// `tester.tap(find.byKey(...))` 可直接命中 onTap 分支(applyOp)。
  Future<void> tapOpKey(WidgetTester tester, Key anchor) async {
    await tester.tap(find.byKey(anchor), warnIfMissed: false);
    await tester.pump();
    // InkWell 同时注册 onTap/onDoubleTap:单击回调要等双击判定窗口
    // (kDoubleTapTimeout 300ms)过去才触发,故推进 400ms。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  Future<void> tapDoneKey(WidgetTester tester) async {
    await tester.tap(find.byKey(AmountEditorSheet.doneKeyAnchor),
        warnIfMissed: false);
    await tester.pump();
  }

  /// 读当前金额显示位(排除键盘按键上的同名文本)。
  String display(WidgetTester tester) {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .toList();
    for (final t in texts) {
      if (RegExp(r'^[0-9]+([.][0-9]+)?$').hasMatch(t)) return t;
    }
    return '?';
  }

  // ── 零 / 负 / 精度 ──

  testWidgets('零金额:完成键禁用,点击不触发 onSubmit', (tester) async {
    var submitted = 0;
    await tester.pumpWidget(host(onSubmit: (_) => submitted++));
    await tester.pumpAndSettle();

    await tapKey(tester, '完成');
    await tester.pumpAndSettle();
    expect(submitted, 0, reason: '0 金额不得提交');
  });

  testWidgets('负初值:-25.5 提交后金额取绝对值 25.5', (tester) async {
    double? got;
    await tester.pumpWidget(host(
      initialAmount: -25.5,
      onSubmit: (v) => got = v.amount,
    ));
    await tester.pumpAndSettle();

    await tapKey(tester, '完成');
    await tester.pumpAndSettle();
    expect(got, 25.5, reason: '金额语义恒为正数(方向由类型表达)');
  });

  testWidgets('多点号:连点两次 "." 只保留一个', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tapKey(tester, '.');
    await tapKey(tester, '.');
    expect(find.text('0.'), findsOneWidget, reason: '第二个点号应被忽略');
  });

  testWidgets('超精度:小数点后第三位被忽略', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await typeDigits(tester, '1.234');
    expect(find.text('1.23'), findsOneWidget);
  });

  testWidgets('前导零:输入 0 后直接输 5 得 "5" 不含前导零', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tapKey(tester, '5');
    expect(display(tester), '5', reason: '显示位应为 5(keypad 上也有 "5" 键文本)');
  });

  // ── 超长数字(U-1:位数上限 + 提交前 isFinite) ──

  testWidgets('U-1:超长数字输入在窄屏不溢出(整数位上限 12)', (tester) async {
    // 攻击:键盘输入无位数上限,Row 里的金额 Text 不可收缩 → 窄屏必溢出。
    // 修复:_append 整数位上限 12 + 表达式行 FittedBox(scaleDown)。
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await typeDigits(tester, '99999999999999999999'); // 20 位
    await tester.pump();

    final ex = tester.takeException();
    expect(ex, isNull, reason: '超长数字在 320 宽屏应不溢出,实际异常=$ex');
    expect(display(tester), '999999999999', reason: '整数位上限 12,多输的位被忽略');
  });

  testWidgets('U-1:超长数字提交值必须是有限数(310 位 → 不是 Infinity)', (tester) async {
    // 攻击:double.parse 对 310 位数字溢出为 Infinity;提交后落库污染统计。
    // 修复:位数上限(第一道闸)+ 提交前 total.isFinite(兜底断言)。
    double? got;
    await tester.pumpWidget(host(onSubmit: (v) => got = v.amount));
    await tester.pumpAndSettle();

    await typeDigits(tester, '9' * 310);
    await tester.pump();
    // 渲染溢出异常先消费掉,聚焦数值断言
    while (tester.takeException() != null) {}

    expect(display(tester), '999999999999', reason: '输入被截到 12 位上限');
    await tapKey(tester, '完成');
    await tester.pumpAndSettle();

    expect(got, isNotNull, reason: '上限内的值应可正常提交');
    expect(got!.isFinite, isTrue,
        reason: '提交金额必须是有限数,实际=$got(310 位溢出为 Infinity)');
    expect(got, 999999999999.0, reason: '提交值等于截断后的 12 位');
  });

  testWidgets('U-1:小数位上限 2(第三位小数被忽略)', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await typeDigits(tester, '1.2345');
    expect(display(tester), '1.23', reason: '小数位上限 2');
  });

  testWidgets('U-1:整数位上限不误伤正常大额(12 位可完整输入)', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await typeDigits(tester, '123456789012');
    expect(display(tester), '123456789012', reason: '恰好 12 位应完整保留');
  });

  // ── 双击提交 ──

  testWidgets('双击完成:onSubmit 只调用一次(防重入闸门)', (tester) async {
    var calls = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(host(onSubmit: (v) async {
      calls++;
      await gate.future;
    }));
    await tester.pumpAndSettle();
    await tapKey(tester, '5');

    // 两次点击之间不 pump:第二次点击命中旧 widget,但 _isSubmitting 已 true
    await tester.tap(find.widgetWithText(InkWell, '完成').first);
    await tester.tap(find.widgetWithText(InkWell, '完成').first);
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    expect(calls, 1, reason: '快速双击不得产生两笔提交');
  });

  // ── 运算模式(可测性 1,2026-10-11 批次 X 修复后可达) ──
  //
  // 此前结论「运算符键 onTap 不可达」是**测试手法问题**:运算符键的标签是
  // `Text.rich`,旧 `find.widgetWithText` 拿不到;而 onTap/onDoubleTap 共存
  // 时单击回调要等 kDoubleTapTimeout(300ms)过去才触发 —— 旧探针没有推进
  // 这个窗口,所以 display 不变。产品代码补 Key 锚点后
  // `tester.tap(find.byKey(opKey1Anchor))` + pump(400ms) 即可驱动 applyOp,
  // 完成键同理驱动 applyEquals(纯等号语义从此有 widget 级覆盖)。
  // applyOp/applyEquals 的实现见 amount_editor_sheet.dart(Decimal 运算 +
  // 除零返回被除数 + 结果 round(2))。

  testWidgets('运算模式:tap 运算符键 → 完成键变 "=" 且不提交', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(onSubmit: (_) => calls++));
    await tester.pumpAndSettle();
    await tapKey(tester, '5');
    await tapOpKey(tester, AmountEditorSheet.opKey1Anchor);
    // 运算模式:完成键文案变 "=",且此刻点击不触发提交
    expect(find.text('='), findsOneWidget, reason: '运算符应用后进入运算模式');
    await tapDoneKey(tester);
    await tester.pumpAndSettle();
    expect(calls, 0, reason: '运算模式下完成键=等号,不得提交');
  });

  testWidgets('运算模式:10 + 5 = 15,完成键提交 15', (tester) async {
    double? got;
    await tester.pumpWidget(host(onSubmit: (v) => got = v.amount));
    await tester.pumpAndSettle();
    await tapKey(tester, '1');
    await tapKey(tester, '0');
    await tapOpKey(tester, AmountEditorSheet.opKey1Anchor);
    await tapKey(tester, '5');
    await tapDoneKey(tester); // 等号:15
    await tester.pumpAndSettle();
    expect(display(tester), '15', reason: 'applyEquals 结果回填显示位');
    await tapDoneKey(tester); // 已退出运算模式 → 提交
    await tester.pumpAndSettle();
    expect(got, 15.0, reason: '等号结果作为金额提交');
  });

  testWidgets('运算模式:连点等号后完成键提交运算结果(非重入)', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(onSubmit: (_) => calls++));
    await tester.pumpAndSettle();
    await tapKey(tester, '2');
    await tapOpKey(tester, AmountEditorSheet.opKey2Anchor); // 激活运算符为减号
    await tapKey(tester, '1');
    await tapDoneKey(tester);
    await tester.pumpAndSettle();
    // 已退出运算模式:再点完成是提交,不是再次等号
    await tapDoneKey(tester);
    await tester.pumpAndSettle();
    expect(calls, 1, reason: '等号只回填结果,提交由下一次完成键触发');
  });

  testWidgets('HARDENING:除零保护(÷ 0)返回被除数且仍有限', (tester) async {
    double? got;
    await tester.pumpWidget(host(onSubmit: (v) => got = v.amount));
    await tester.pumpAndSettle();
    await tapKey(tester, '8');
    // 长按第二运算符键切到乘除组(÷),单击应用
    await tester.longPress(find.byKey(AmountEditorSheet.opKey2Anchor),
        warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tapKey(tester, '0');
    await tapDoneKey(tester); // 8 ÷ 0 → 除零保护返回被除数 8
    await tester.pumpAndSettle();
    expect(display(tester), '8', reason: '除零保护:保持被除数不变');
    await tapDoneKey(tester);
    await tester.pumpAndSettle();
    expect(got, 8.0);
    expect(got!.isFinite, isTrue, reason: '除零不得产生 Infinity/NaN');
  });

  // ── 大字体与窄屏布局 ──

  testWidgets('大字体(2.0):键盘与标题不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: host(),
    ));
    await tester.pumpAndSettle();
    final ex = tester.takeException();
    expect(ex, isNull, reason: '大字体下不得渲染溢出,实际=$ex');
  });

  testWidgets('窄屏 320:键盘可见且不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final ex = tester.takeException();
    expect(ex, isNull, reason: '320 宽下键盘不得溢出,实际=$ex');
  });

  // ── 备注与日期 ──

  testWidgets('备注超长/emoji 不崩,提交原样透传', (tester) async {
    String? note;
    await tester.pumpWidget(host(onSubmit: (v) => note = v.note));
    await tester.pumpAndSettle();
    await tapKey(tester, '5');
    // 直接写备注输入框
    final field = find.byType(TextField).first;
    await tester.enterText(field, '🚀' * 200);
    await tester.pump();
    await tapKey(tester, '完成');
    await tester.pumpAndSettle();
    expect(note, isNotNull);
    expect(note!.length, 400, reason: '备注入参是 UTF-16 单元长度 400');
  });

  testWidgets('月末日期初值原样提交(不做月末顺延)', (tester) async {
    DateTime? got;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        currentLedgerProvider
            .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: AmountEditorSheet(
            categoryName: '餐饮',
            initialDate: DateTime(2026, 1, 31),
            initialAmount: 10,
            ledgerId: 1,
            onSubmit: (v) => got = v.date,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tapKey(tester, '完成');
    await tester.pumpAndSettle();
    expect(got, DateTime(2026, 1, 31), reason: '1/31 不得被顺延为 3 月');
  });

  testWidgets('空金额 + 纯小数 "0." 视为 0 → 不可提交', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(onSubmit: (_) => calls++));
    await tester.pumpAndSettle();
    await tapKey(tester, '.');
    await tapKey(tester, '完成');
    await tester.pumpAndSettle();
    expect(calls, 0, reason: '"0." 求值为 0,不得提交');
  });
}

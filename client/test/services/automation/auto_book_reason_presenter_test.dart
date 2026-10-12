import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/services/automation/auto_book_reason_presenter.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  group('两级原因覆盖(B1 任务 4)', () {
    test('硬过滤 time_missing:可读文案 + 可补记', () {
      final view = AutoBookReasonPresenter.present(l10n,
          reason: 'time_missing', state: 'ignored');
      expect(view.level, AutoBookReasonLevel.hardFiltered);
      expect(view.canManualAdd, isTrue);
      expect(view.title, l10n.autoBookReasonTimeMissing);
      // 普通列表文案不能是原始码
      expect(view.title, isNot('time_missing'));
    });

    test('硬过滤 time_inferred:推测时间不入账且可补记', () {
      final view = AutoBookReasonPresenter.present(l10n,
          reason: 'time_inferred', state: 'ignored');
      expect(view.level, AutoBookReasonLevel.hardFiltered);
      expect(view.canManualAdd, isTrue);
      expect(view.title, l10n.autoBookReasonTimeInferred);
    });

    test('待确认 time_precision_weak:需确认时间,不提供直接补记', () {
      final view = AutoBookReasonPresenter.present(l10n,
          reason: 'time_precision_weak', state: 'pending');
      expect(view.level, AutoBookReasonLevel.pendingReview);
      expect(view.canManualAdd, isFalse);
      expect(view.title, l10n.autoBookReasonTimePrecisionWeak);
    });

    test('其余硬过滤与待确认原因都有归属', () {
      for (final code in AutoBookReasonPresenter.hardFilterReasons) {
        expect(
          AutoBookReasonPresenter.levelFor(code),
          AutoBookReasonLevel.hardFiltered,
          reason: code,
        );
      }
      for (final code in const [
        'settlement_unknown',
        'confidence_missing',
        'event_kind_unknown',
        'transfer_account_missing',
        'pending_confirmation',
        'timePrecisionWeak',
        'confidenceMissing',
      ]) {
        expect(
          AutoBookReasonPresenter.levelFor(code),
          AutoBookReasonLevel.pendingReview,
          reason: code,
        );
      }
    });

    test('判重/失败/正常原因分别归类', () {
      expect(AutoBookReasonPresenter.levelFor('duplicate'),
          AutoBookReasonLevel.duplicate);
      expect(AutoBookReasonPresenter.levelFor('already_processed'),
          AutoBookReasonLevel.duplicate);
      expect(AutoBookReasonPresenter.levelFor('ai_retryable'),
          AutoBookReasonLevel.retryable);
      expect(AutoBookReasonPresenter.levelFor('ai_not_configured'),
          AutoBookReasonLevel.retryable);
      expect(AutoBookReasonPresenter.levelFor('evidence_missing'),
          AutoBookReasonLevel.terminal);
      expect(AutoBookReasonPresenter.levelFor('settled_transaction'),
          AutoBookReasonLevel.booked);
      expect(AutoBookReasonPresenter.levelFor('shadow_mode'),
          AutoBookReasonLevel.info);
    });
  });

  group('未知原因兜底', () {
    test('未知码 + 忽略态 → 可读兜底,原码只进诊断', () {
      final view = AutoBookReasonPresenter.present(l10n,
          reason: 'some_new_internal_code', state: 'ignored');
      expect(view.title, isNot('some_new_internal_code'));
      expect(view.title, l10n.autoBookReasonUnknownIgnored);
      expect(view.diagnostic, contains('some_new_internal_code'));
    });

    test('无原因 + 失败态 → 按状态兜底', () {
      final view = AutoBookReasonPresenter.present(l10n, state: 'failed');
      expect(view.title, l10n.autoBookReasonUnknownFailed);
      expect(view.level, AutoBookReasonLevel.terminal);
    });

    test('lastError 不进普通文案,只进诊断区', () {
      final view = AutoBookReasonPresenter.present(l10n,
          reason: 'ai_retryable', state: 'retry', lastError: 'boom secret');
      expect(view.title, isNot(contains('boom secret')));
      expect(view.diagnostic, contains('ai_retryable'));
      expect(view.diagnostic, contains('boom secret'));
    });

    test('无原因且无错误时诊断为空', () {
      final view = AutoBookReasonPresenter.present(l10n, state: 'booked');
      expect(view.diagnostic, isNull);
    });
  });

  group('状态与来源标签统一', () {
    test('九态都有中文标签,未知态回落原值', () {
      for (final state in const [
        'captured',
        'processing',
        'pending',
        'booked',
        'duplicate',
        'ignored',
        'retry',
        'failed',
        'expired',
      ]) {
        expect(AutoBookReasonPresenter.stateLabel(state), isNot(state));
      }
      expect(AutoBookReasonPresenter.stateLabel('weird'), 'weird');
    });

    test('主要来源有中文标签', () {
      expect(AutoBookReasonPresenter.sourceLabel('sms'), '短信');
      expect(AutoBookReasonPresenter.sourceLabel('notification'), '通知');
      expect(AutoBookReasonPresenter.sourceLabel('screenText'), '详情页');
      expect(AutoBookReasonPresenter.sourceLabel('screenshot'), '截图');
    });
  });
}

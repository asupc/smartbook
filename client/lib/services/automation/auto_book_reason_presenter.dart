import '../../l10n/app_localizations.dart';

/// 原因的语义层级(B1 统一原因映射)。
///
/// 同一个 reason 码在历史页、详情页、首页状态卡、补记按钮四处展示,
/// 各自写一份 switch 必然漂移;层级决定「文案 + 可用动作」。
enum AutoBookReasonLevel {
  /// 硬过滤:自动入口直接丢弃,未生成交易也未进待确认(时间缺失/推测等)。
  /// 这类事件允许用户**主动**补记。
  hardFiltered,

  /// 进入待确认,等用户裁决。
  pendingReview,

  /// 与已有记录判重命中。
  duplicate,

  /// 可重试失败(网络/未就绪),事件仍在重试或暂存。
  retryable,

  /// 终态失败或证据已消失,重试不会变好。
  terminal,

  /// 已正常入账。
  booked,

  /// 中性结果(演练、非账单、手动路径),不构成问题。
  info,
}

/// 一条原因的展示模型。
class AutoBookReasonView {
  const AutoBookReasonView({
    required this.title,
    required this.level,
    this.diagnostic,
    this.canManualAdd = false,
  });

  /// 面向用户的可读原因(普通列表/状态卡直接展示)。
  final String title;

  final AutoBookReasonLevel level;

  /// 内部原因码 + 错误信息,只进「可展开诊断区」,不进普通列表。
  final String? diagnostic;

  /// 是否给「补记」入口(仅硬过滤;还要看事件是否留有可用结构化摘要)。
  final bool canManualAdd;

  bool get isIssue =>
      level == AutoBookReasonLevel.hardFiltered ||
      level == AutoBookReasonLevel.terminal ||
      level == AutoBookReasonLevel.retryable;
}

/// 自动记账原因 → 用户文案 的唯一映射(B1 任务 4)。
///
/// 覆盖两级原因:
/// - 硬过滤 `time_missing` / `time_inferred`(直接丢弃,可补记);
/// - 待确认 `time_precision_weak` 等(进候选,需用户裁决)。
///
/// 未知原因码**不透传给普通列表**:按事件状态给可读兜底,原始码只放
/// [AutoBookReasonView.diagnostic] 供诊断区展开。
class AutoBookReasonPresenter {
  const AutoBookReasonPresenter._();

  static const Set<String> hardFilterReasons = {
    'time_missing',
    'time_inferred',
    'invalid_amount',
    'statement_or_balance',
    'unsettled_order',
  };

  static AutoBookReasonView present(
    AppLocalizations l10n, {
    String? reason,
    String? state,
    String? lastError,
  }) {
    final code = (reason ?? '').trim();
    final diagnostic = _diagnostic(code, lastError);

    if (code.isEmpty) {
      return AutoBookReasonView(
        title: _fallbackForState(l10n, state),
        level: _levelForState(state),
        diagnostic: diagnostic,
      );
    }

    final known = _knownTitle(l10n, code);
    if (known == null) {
      return AutoBookReasonView(
        title: _fallbackForState(l10n, state),
        level: _levelForState(state),
        diagnostic: diagnostic,
      );
    }

    final level = levelFor(code, state: state);
    return AutoBookReasonView(
      title: known,
      level: level,
      diagnostic: diagnostic,
      canManualAdd: level == AutoBookReasonLevel.hardFiltered,
    );
  }

  /// reason 码 → 层级(公开给状态卡/按钮复用判定)。
  static AutoBookReasonLevel levelFor(String? code, {String? state}) {
    final key = (code ?? '').trim();
    if (key.isEmpty) return _levelForState(state);

    if (const {
      'duplicate',
      'already_processed',
      'semantic_duplicate',
    }.contains(key)) {
      return AutoBookReasonLevel.duplicate;
    }
    if (const {
      'ai_retryable',
      'ai_not_configured',
      'relay_not_ready',
    }.contains(key)) {
      return AutoBookReasonLevel.retryable;
    }
    if (const {
      'ai_permanent_failure',
      'evidence_missing',
      'draft_evidence_missing',
      'auth_expired',
      // B2:目标失效/待确定 —— 事件停在 captured 等用户修目标,对用户是
      // 「必须处理」的问题,不是中性信息。
      'target_invalid',
      'target_undetermined',
    }.contains(key)) {
      return AutoBookReasonLevel.terminal;
    }
    if (const {
      'pending_confirmation',
      'confidence_missing',
      'settlement_unknown',
      'event_kind_unknown',
      'transfer_account_missing',
      'time_precision_weak',
      'lowConfidence',
      'confidenceMissing',
      'timePrecisionWeak',
      'settlementUnknown',
      'transferAccountMissing',
      'autoBookDisabled',
      // B2:用户账户规则命中但无法验证 → 待确认裁决。
      'accountRuleConflict',
    }.contains(key)) {
      return AutoBookReasonLevel.pendingReview;
    }
    if (hardFilterReasons.contains(key)) {
      return AutoBookReasonLevel.hardFiltered;
    }
    if (const {
      'user_initiated',
      'shadow_mode',
      'no_bill',
      'ai_unavailable',
      'large',
      'anomaly',
    }.contains(key)) {
      return AutoBookReasonLevel.info;
    }
    if (const {'settled_transaction', 'settled_financial_event'}
        .contains(key)) {
      return AutoBookReasonLevel.booked;
    }
    // 事件级语义未知 → 交给状态兜底,不硬归类。
    return _levelForState(state);
  }

  /// 状态码 → 用户文案(历史页/详情页共用,替代两页各自私有的 `_stateLabel`)。
  static String stateLabel(String state) => switch (state) {
        'captured' => '已捕获',
        'processing' => '处理中',
        'pending' => '待确认',
        'booked' => '已入账',
        'duplicate' => '已去重',
        'ignored' => '已忽略',
        'retry' => '待重试',
        'failed' => '失败',
        'expired' => '已过期',
        _ => state,
      };

  /// 来源码 → 用户文案(同上,替代两页各自私有的 `_sourceLabel`)。
  static String sourceLabel(String source) => switch (source) {
        'sms' => '短信',
        'notification' => '通知',
        'screenText' => '详情页',
        'screenshot' => '截图',
        'sharedImage' => '分享图片',
        'import' => '导入',
        'recurring' => '周期交易',
        'deepLinkText' || 'deepLinkDirect' => 'Deep Link',
        _ => source,
      };

  static String? _knownTitle(AppLocalizations l10n, String code) {
    return switch (code) {
      // ── 硬过滤(未入账,可主动补记) ──
      'time_missing' => l10n.autoBookReasonTimeMissing,
      'time_inferred' => l10n.autoBookReasonTimeInferred,
      'invalid_amount' => l10n.autoBookReasonInvalidAmount,
      'statement_or_balance' => l10n.autoBookReasonStatementOrBalance,
      'unsettled_order' => l10n.autoBookReasonUnsettledOrder,

      // ── 待确认 ──
      'time_precision_weak' => l10n.autoBookReasonTimePrecisionWeak,
      'confidence_missing' => l10n.pendingCandidateReasonConfidenceMissing,
      'settlement_unknown' => l10n.pendingCandidateReasonSettlementUnknown,
      'event_kind_unknown' => l10n.pendingCandidateReasonSettlementUnknown,
      'transfer_account_missing' =>
        l10n.pendingCandidateReasonTransferAccountMissing,
      'pending_confirmation' => l10n.autoBookReasonPendingConfirmation,
      'accountRuleConflict' => l10n.autoBookReasonAccountRuleConflict,
      'target_invalid' => l10n.autoBookReasonTargetInvalid,
      'target_undetermined' => l10n.autoBookReasonTargetUndetermined,
      'lowConfidence' => l10n.pendingCandidateReasonLowConfidence,
      'confidenceMissing' => l10n.pendingCandidateReasonConfidenceMissing,
      'timeInferred' => l10n.pendingCandidateReasonTimeInferred,
      'timePrecisionWeak' => l10n.pendingCandidateReasonTimePrecisionWeak,
      'settlementUnknown' => l10n.pendingCandidateReasonSettlementUnknown,
      'transferAccountMissing' =>
        l10n.pendingCandidateReasonTransferAccountMissing,
      'autoBookDisabled' => l10n.pendingCandidateReasonAutoBookDisabled,

      // ── 判重 ──
      'duplicate' => l10n.pendingCandidateReasonDuplicate,
      'already_processed' => l10n.pendingCandidateReasonAlreadyProcessed,
      'semantic_duplicate' => l10n.pendingCandidateReasonDuplicate,

      // ── 失败/暂存 ──
      'ai_not_configured' => l10n.autoBookReasonAiNotConfigured,
      'ai_retryable' => l10n.autoBookReasonAiRetryable,
      'ai_permanent_failure' => l10n.autoBookReasonAiPermanentFailure,
      'auth_expired' => l10n.autoBookReasonAuthExpired,
      'ai_unavailable' => l10n.autoBookReasonAiUnavailable,
      'evidence_missing' => l10n.autoBookReasonEvidenceMissing,
      'draft_evidence_missing' => l10n.autoBookReasonDraftEvidenceMissing,

      // ── 中性/正常 ──
      'shadow_mode' => l10n.autoBookReasonShadowMode,
      'no_bill' => l10n.autoBookReasonNoBill,
      'user_initiated' => l10n.autoBookReasonUserInitiated,
      'settled_transaction' => l10n.autoBookReasonSettledTransaction,
      'settled_financial_event' => l10n.autoBookReasonSettledFinancialEvent,
      'large' => l10n.pendingCandidateReasonLarge,
      'anomaly' => l10n.pendingCandidateReasonAnomaly,
      _ => null,
    };
  }

  static String _fallbackForState(AppLocalizations l10n, String? state) {
    return switch (state) {
      'booked' => l10n.autoBookReasonSettledTransaction,
      'pending' => l10n.autoBookReasonPendingConfirmation,
      'duplicate' => l10n.pendingCandidateReasonDuplicate,
      'retry' => l10n.autoBookReasonAiRetryable,
      'failed' => l10n.autoBookReasonUnknownFailed,
      'expired' => l10n.autoBookReasonUnknownExpired,
      'ignored' => l10n.autoBookReasonUnknownIgnored,
      _ => l10n.autoBookReasonUnknown,
    };
  }

  static AutoBookReasonLevel _levelForState(String? state) {
    return switch (state) {
      'booked' => AutoBookReasonLevel.booked,
      'pending' => AutoBookReasonLevel.pendingReview,
      'duplicate' => AutoBookReasonLevel.duplicate,
      'retry' => AutoBookReasonLevel.retryable,
      'failed' || 'expired' => AutoBookReasonLevel.terminal,
      'ignored' || 'captured' || 'processing' => AutoBookReasonLevel.info,
      _ => AutoBookReasonLevel.info,
    };
  }

  /// 原始码 + 错误串拼成诊断文本。**只进可展开诊断区**,普通列表不展示
  /// (历史页曾把 lastError 直接拼进列表项,违反「不展示堆栈或凭据」)。
  static String? _diagnostic(String code, String? lastError) {
    final err = (lastError ?? '').trim();
    if (code.isEmpty && err.isEmpty) return null;
    if (code.isEmpty) return err;
    if (err.isEmpty) return code;
    return '$code\n$err';
  }
}

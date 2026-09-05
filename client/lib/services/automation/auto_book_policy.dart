import '../../ai/core/bill_info.dart';

/// 自动入口对一笔 AI 结果的处理建议。
enum AutoBookPolicyAction {
  allow,
  pending,
  ignore,
}

class AutoBookPolicyDecision {
  final AutoBookPolicyAction action;
  final String reason;
  final BillEventKind? eventKind;
  final BillSettlementStatus? settlementStatus;

  const AutoBookPolicyDecision({
    required this.action,
    required this.reason,
    this.eventKind,
    this.settlementStatus,
  });

  bool get isAllowed => action == AutoBookPolicyAction.allow;
  bool get isPending => action == AutoBookPolicyAction.pending;
  bool get isIgnored => action == AutoBookPolicyAction.ignore;
}

/// 自动记账语义硬闸门。
///
/// 关键词只做便宜的前置/兜底判断，最终仍以 AI 的结构化字段为主。主动
/// 用户路径不经过本类，避免把用户明确说出的内容静默丢弃。
class AutoBookPolicy {
  static final _summaryPattern = RegExp(
    r'本期账单|账单总额|本期应还|最低还款|应还款|还款日|账单日|可用额度|当前余额|余额提醒|积分余额',
  );
  static final _pendingPattern = RegExp(
    r'待支付|待付款|订单确认|尚未支付|未支付|交易关闭|支付失败|付款失败|预授权|冻结金额|处理中',
  );
  static final _settledPattern = RegExp(
    r'支付成功|付款成功|交易成功|已支付|已付款|支付完成|扣款成功|消费成功|退款成功|收款到账|交易完成',
  );
  static final _transferPattern = RegExp(r'转账|转帐|还款|充值|提现|汇入|汇出');
  static final _feePattern = RegExp(r'手续费|服务费|利息|fee');
  static final _refundPattern = RegExp(r'退款|退费|冲正');

  const AutoBookPolicy();

  /// 在进入 BillCreationService 前把“证据语义”映射为账务方向。
  ///
  /// AI 有时会把退款/还款统一输出成 expense；如果只依赖 BillType，跨入口
  /// 判重和统计都会反向污染。这里不改变用户主动路径的拦截策略，只修正
  /// 已经由结构化字段/证据文本明确的方向。
  BillInfo normalizeForPersistence({
    required BillInfo bill,
    String? evidenceText,
  }) {
    final text = evidenceText?.trim() ?? '';
    final kind = bill.eventKind ?? _inferKind(bill, text);
    final status = bill.settlementStatus ?? _inferStatus(text);
    final type = switch (kind) {
      BillEventKind.refund || BillEventKind.income => BillType.income,
      BillEventKind.transfer ||
      BillEventKind.repayment ||
      BillEventKind.recharge =>
        BillType.transfer,
      BillEventKind.purchase || BillEventKind.fee => BillType.expense,
      _ => bill.type,
    };
    final amount = switch (kind) {
      BillEventKind.income ||
      BillEventKind.refund ||
      BillEventKind.purchase ||
      BillEventKind.fee ||
      BillEventKind.transfer ||
      BillEventKind.repayment ||
      BillEventKind.recharge =>
        bill.amount?.abs(),
      _ => bill.amount,
    };
    return bill.copyWith(
      amount: amount,
      type: type,
      eventKind: kind,
      settlementStatus: status,
    );
  }

  /// [automatic] 为 false 时只返回 allow；手动路径必须由用户决定。
  AutoBookPolicyDecision evaluate({
    required BillInfo bill,
    required String source,
    String? evidenceText,
    bool automatic = true,
  }) {
    final text = evidenceText?.trim() ?? '';
    final inferredKind = bill.eventKind ?? _inferKind(bill, text);
    final inferredStatus = bill.settlementStatus ?? _inferStatus(text);

    if (!automatic) {
      return AutoBookPolicyDecision(
        action: AutoBookPolicyAction.allow,
        reason: 'user_initiated',
        eventKind: inferredKind,
        settlementStatus: inferredStatus,
      );
    }

    final amount = bill.amount;
    if (amount == null || amount.abs() <= 0) {
      return AutoBookPolicyDecision(
        action: AutoBookPolicyAction.ignore,
        reason: 'invalid_amount',
        eventKind: inferredKind,
        settlementStatus: inferredStatus,
      );
    }

    if (inferredKind == BillEventKind.statement ||
        inferredKind == BillEventKind.balanceReminder ||
        inferredStatus == BillSettlementStatus.summary) {
      return AutoBookPolicyDecision(
        action: AutoBookPolicyAction.ignore,
        reason: 'statement_or_balance',
        eventKind: inferredKind,
        settlementStatus: inferredStatus,
      );
    }

    if (inferredKind == BillEventKind.pendingOrder ||
        inferredStatus == BillSettlementStatus.pending ||
        inferredStatus == BillSettlementStatus.failed ||
        inferredStatus == BillSettlementStatus.cancelled ||
        inferredStatus == BillSettlementStatus.reversed) {
      return AutoBookPolicyDecision(
        action: AutoBookPolicyAction.ignore,
        reason: 'unsettled_order',
        eventKind: inferredKind,
        settlementStatus: inferredStatus,
      );
    }

    if (inferredKind == null || inferredKind == BillEventKind.unknown) {
      return AutoBookPolicyDecision(
        action: AutoBookPolicyAction.pending,
        reason: 'event_kind_unknown',
        eventKind: inferredKind,
        settlementStatus: inferredStatus,
      );
    }

    if (inferredKind == BillEventKind.transfer ||
        inferredKind == BillEventKind.repayment ||
        inferredKind == BillEventKind.recharge) {
      final hasFrom = _nonEmpty(bill.fromAccount);
      final hasTo = _nonEmpty(bill.toAccount);
      final hasAccount = _nonEmpty(bill.account);
      if (!hasFrom && !hasTo && !hasAccount) {
        return AutoBookPolicyDecision(
          action: AutoBookPolicyAction.pending,
          reason: 'transfer_account_missing',
          eventKind: inferredKind,
          settlementStatus: inferredStatus,
        );
      }
    }

    if (inferredKind == BillEventKind.refund ||
        inferredKind == BillEventKind.fee ||
        inferredKind == BillEventKind.income) {
      // 这些可以是实际结算事件，但仍要求明确结算状态；文本里的退款/到账
      // 作为旧模型兼容的强证据。
      if (inferredStatus == BillSettlementStatus.settled ||
          _settledPattern.hasMatch(text) ||
          _refundPattern.hasMatch(text)) {
        return AutoBookPolicyDecision(
          action: AutoBookPolicyAction.allow,
          reason: 'settled_financial_event',
          eventKind: inferredKind,
          settlementStatus: inferredStatus,
        );
      }
    }

    // 自动路径缺少显式结算状态时默认进入候选；但有明确的成功文本时，
    // 兼容旧模型的结构化输出，允许继续走重复检测。
    if (inferredStatus == null ||
        inferredStatus == BillSettlementStatus.unknown) {
      if (!_settledPattern.hasMatch(text)) {
        return AutoBookPolicyDecision(
          action: AutoBookPolicyAction.pending,
          reason: 'settlement_unknown',
          eventKind: inferredKind,
          settlementStatus: inferredStatus,
        );
      }
    }

    if (!bill.confidenceProvided || bill.timeInferred) {
      return AutoBookPolicyDecision(
        action: AutoBookPolicyAction.pending,
        reason:
            !bill.confidenceProvided ? 'confidence_missing' : 'time_inferred',
        eventKind: inferredKind,
        settlementStatus: inferredStatus,
      );
    }

    final precision = bill.timePrecision;
    if (precision == null ||
        precision == BillTimePrecision.unknown ||
        precision == BillTimePrecision.inferred ||
        precision == BillTimePrecision.date) {
      return AutoBookPolicyDecision(
        action: AutoBookPolicyAction.pending,
        reason: 'time_precision_weak',
        eventKind: inferredKind,
        settlementStatus: inferredStatus,
      );
    }

    return AutoBookPolicyDecision(
      action: AutoBookPolicyAction.allow,
      reason: 'settled_transaction',
      eventKind: inferredKind,
      settlementStatus: inferredStatus,
    );
  }

  BillEventKind? _inferKind(BillInfo bill, String text) {
    if (_summaryPattern.hasMatch(text)) return BillEventKind.statement;
    if (_pendingPattern.hasMatch(text)) return BillEventKind.pendingOrder;
    if (_refundPattern.hasMatch(text)) return BillEventKind.refund;
    if (_feePattern.hasMatch(text)) return BillEventKind.fee;
    if (_transferPattern.hasMatch(text)) {
      if (text.contains('还款')) return BillEventKind.repayment;
      if (text.contains('充值')) return BillEventKind.recharge;
      return BillEventKind.transfer;
    }
    return switch (bill.type) {
      BillType.income => BillEventKind.income,
      BillType.transfer => BillEventKind.transfer,
      BillType.expense => BillEventKind.purchase,
      null => null,
    };
  }

  BillSettlementStatus? _inferStatus(String text) {
    if (text.isEmpty) return null;
    if (_summaryPattern.hasMatch(text)) return BillSettlementStatus.summary;
    if (_pendingPattern.hasMatch(text)) return BillSettlementStatus.pending;
    if (_settledPattern.hasMatch(text)) return BillSettlementStatus.settled;
    return null;
  }

  bool _nonEmpty(String? value) => value != null && value.trim().isNotEmpty;
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db.dart' as schema;
import '../../providers/database_providers.dart';
import '../../providers/sync_providers.dart';
import '../system/logger_service.dart';

/// 自动记账目标账本引用(B2:捕获时冻结的稳定标识)。
///
/// 口径见 `client/docs/plans/B0-基线与状态字段约定-2026-10-10.md` §3:
/// - 有 syncId 用 syncId(跨设备稳定);
/// - syncId 为空的历史本地账本用 localId,**必须带 scope**;
/// - 共享账本写本机账本行,不写镜像表的临时映射 ID。
class AutoBookTarget {
  const AutoBookTarget({
    required this.scope,
    required this.kind,
    required this.value,
    this.accountId,
    this.confirmedAt,
    this.migratedFrom,
  });

  /// 'local' 或 'user:<userId>'。切账号后 scope 不匹配即判定失效。
  final String scope;

  /// 'syncId' | 'localId'
  final String kind;

  final String value;
  final int? accountId;

  /// null = 由旧口径迁移而来,**尚未被用户确认**。
  final DateTime? confirmedAt;

  /// 'legacy_current_ledger' = 首次升级时沿用当时有效账本一次。
  final String? migratedFrom;

  bool get confirmed => confirmedAt != null;

  Map<String, dynamic> toJson() => {
        'scope': scope,
        'kind': kind,
        'value': value,
        if (accountId != null) 'accountId': accountId,
        if (confirmedAt != null) 'confirmedAt': confirmedAt!.toIso8601String(),
        if (migratedFrom != null) 'migratedFrom': migratedFrom,
      };

  static AutoBookTarget? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    final value = raw['value'];
    final scope = raw['scope'];
    if (kind is! String || value is! String || value.isEmpty) return null;
    if (scope is! String || scope.isEmpty) return null;
    return AutoBookTarget(
      scope: scope,
      kind: kind,
      value: value,
      accountId: raw['accountId'] is int ? raw['accountId'] as int : null,
      confirmedAt: DateTime.tryParse('${raw['confirmedAt'] ?? ''}'),
      migratedFrom:
          raw['migratedFrom'] is String ? raw['migratedFrom'] as String : null,
    );
  }
}

/// 开通引导进度(B1):逐步保存,允许暂时跳过非必要来源。
class AutoBookSetupProgress {
  const AutoBookSetupProgress({
    this.serviceChecked = false,
    this.targetChosen = false,
    this.sources = const {},
    this.backgroundChecked = false,
    this.verifiedAt,
    this.verifySkipped = false,
  });

  final bool serviceChecked;
  final bool targetChosen;

  /// 已选择并授权的来源 key(screenshot/sms/notify/screenText)。
  final Set<String> sources;
  final bool backgroundChecked;

  /// 完成一次实际来源验证的时间。
  final DateTime? verifiedAt;

  /// 用户明确选择「暂时跳过验证」:开通仍算完成,但状态卡会保留
  /// 「未做真实验证」提示,不把跳过伪装成已验证。
  final bool verifySkipped;

  bool get verified => verifiedAt != null;

  bool get completed =>
      serviceChecked &&
      targetChosen &&
      sources.isNotEmpty &&
      backgroundChecked &&
      (verifiedAt != null || verifySkipped);

  /// 下一个未完成步骤索引(0 起),供引导页续接。
  int get nextStepIndex {
    if (!serviceChecked) return 0;
    if (!targetChosen) return 1;
    if (sources.isEmpty) return 2;
    if (!backgroundChecked) return 3;
    if (verifiedAt == null && !verifySkipped) return 4;
    return 4;
  }

  AutoBookSetupProgress copyWith({
    bool? serviceChecked,
    bool? targetChosen,
    Set<String>? sources,
    bool? backgroundChecked,
    DateTime? verifiedAt,
    bool? verifySkipped,
  }) =>
      AutoBookSetupProgress(
        serviceChecked: serviceChecked ?? this.serviceChecked,
        targetChosen: targetChosen ?? this.targetChosen,
        sources: sources ?? this.sources,
        backgroundChecked: backgroundChecked ?? this.backgroundChecked,
        verifiedAt: verifiedAt ?? this.verifiedAt,
        verifySkipped: verifySkipped ?? this.verifySkipped,
      );

  Map<String, dynamic> toJson() => {
        'serviceChecked': serviceChecked,
        'targetChosen': targetChosen,
        'sources': sources.toList(),
        'backgroundChecked': backgroundChecked,
        if (verifiedAt != null) 'verifiedAt': verifiedAt!.toIso8601String(),
        if (verifySkipped) 'verifySkipped': true,
      };

  static AutoBookSetupProgress fromJson(Object? raw) {
    if (raw is! Map) return const AutoBookSetupProgress();
    return AutoBookSetupProgress(
      serviceChecked: raw['serviceChecked'] == true,
      targetChosen: raw['targetChosen'] == true,
      sources: (raw['sources'] is List)
          ? (raw['sources'] as List).whereType<String>().toSet()
          : const {},
      backgroundChecked: raw['backgroundChecked'] == true,
      verifiedAt: DateTime.tryParse('${raw['verifiedAt'] ?? ''}'),
      verifySkipped: raw['verifySkipped'] == true,
    );
  }
}

/// 自动记账配置快照(B1 起带版本;B2 追加 target, B5 追加 notifyMode)。
class AutomationSettings {
  const AutomationSettings({
    this.schemaVersion = currentSchemaVersion,
    this.configVersion = 0,
    this.target,
    this.setup = const AutoBookSetupProgress(),
    this.notifyMode,
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;

  /// 单调递增:每次 target/notifyMode 变更 +1,原生缓存按它做版本检查。
  final int configVersion;

  final AutoBookTarget? target;
  final AutoBookSetupProgress setup;

  /// 'every_success' | 'confirm_and_fault' | 'daily_digest'(B5)。
  final String? notifyMode;

  AutomationSettings copyWith({
    int? configVersion,
    AutoBookTarget? target,
    bool clearTarget = false,
    AutoBookSetupProgress? setup,
    String? notifyMode,
  }) =>
      AutomationSettings(
        schemaVersion: schemaVersion,
        configVersion: configVersion ?? this.configVersion,
        target: clearTarget ? null : (target ?? this.target),
        setup: setup ?? this.setup,
        notifyMode: notifyMode ?? this.notifyMode,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'configVersion': configVersion,
        if (target != null) 'target': target!.toJson(),
        'setup': setup.toJson(),
        if (notifyMode != null) 'notifyMode': notifyMode,
      };

  static AutomationSettings fromJson(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return AutomationSettings();
      // 读到更高版本:只读不写,不降级覆盖(B0 §3.1)。
      final schema = map['schemaVersion'];
      return AutomationSettings(
        schemaVersion: schema is int ? schema : currentSchemaVersion,
        configVersion:
            map['configVersion'] is int ? map['configVersion'] as int : 0,
        target: AutoBookTarget.fromJson(map['target']),
        setup: AutoBookSetupProgress.fromJson(map['setup']),
        notifyMode:
            map['notifyMode'] is String ? map['notifyMode'] as String : null,
      );
    } catch (e) {
      logger.warning('AutomationSettings', '配置解析失败,按默认值处理', '$e');
      return AutomationSettings();
    }
  }
}

/// 自动记账配置存储:SharedPreferences 单 key JSON(带版本)。
///
/// 旧设置只读导入、不删除旧值;本 store 不写 `current_ledger_id` 等旧 key。
class AutomationSettingsStore {
  static const String prefsKey = 'auto_book_settings_v1';

  Future<AutomationSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return AutomationSettings();
    return AutomationSettings.fromJson(raw);
  }

  Future<AutomationSettings> save(AutomationSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(settings.toJson()));
    // B0 §3.1:先写 Dart 配置,成功后再同步原生缓存(捕获侧只认已知版本)。
    await pushAutoBookTargetToNative(settings);
    return settings;
  }

  Future<bool> isSetupCompleted() async => (await load()).setup.completed;

  Future<AutoBookSetupProgress> setupProgress() async => (await load()).setup;

  Future<AutoBookSetupProgress> updateSetup(
    AutoBookSetupProgress Function(AutoBookSetupProgress) transform,
  ) async {
    final current = await load();
    final next = current.copyWith(setup: transform(current.setup));
    await save(next);
    return next.setup;
  }

  /// 配置变更:configVersion +1。保存成功后由调用方再刷新原生缓存
  /// (B0 §3.1:先写盘,再同步原生,捕获只认已知版本)。
  Future<AutomationSettings> bumpVersion(AutomationSettings settings) =>
      save(settings.copyWith(configVersion: settings.configVersion + 1));
}

/// 把目标快照同步到原生缓存(B2:捕获入队时冻结进队列项用)。
///
/// 同步失败只降级为「捕获时不冻结」—— Dart 侧仍按当前配置解析目标,
/// 绝不因此回退到浏览账本;不抛给配置保存主流程。
Future<void> pushAutoBookTargetToNative(AutomationSettings settings) async {
  if (!Platform.isAndroid) return;
  try {
    const channel = MethodChannel('com.smartbook.zhi/auto_book_target');
    final target = settings.target;
    await channel.invokeMethod('setCachedTarget', <String, dynamic>{
      'targetRef': target == null ? null : '${target.kind}:${target.value}',
      'targetState': target == null
          ? null
          : (target.confirmed ? 'resolved' : 'unconfirmed'),
      'configVersion': settings.configVersion,
    });
  } catch (e) {
    logger.debug('AutomationSettings', '原生目标缓存同步失败(可降级)', '$e');
  }
}

/// 配置存储实例(无状态,共享即可)。
final automationSettingsStoreProvider =
    Provider<AutomationSettingsStore>((ref) => AutomationSettingsStore());

/// 开通进度:设置页顶部引导卡与「我的」入口共用。
final automationSetupProgressProvider =
    FutureProvider<AutoBookSetupProgress>((ref) async {
  return ref.watch(automationSettingsStoreProvider).setupProgress();
});

/// B5 任务 1:通知偏好三档。
///
/// - [everySuccess]:每笔成功都提醒(升级用户的旧行为,配置缺失时的默认);
/// - [confirmAndFault]:只在**需要确认**或**故障**时提醒(新用户默认);
/// - [dailyDigest]:只发每日汇总(逐笔静默;故障仍即时提醒)。
enum AutoBookNotifyMode {
  everySuccess,
  confirmAndFault,
  dailyDigest;

  static const _every = 'every_success';
  static const _confirm = 'confirm_and_fault';
  static const _digest = 'daily_digest';

  String get storageValue => switch (this) {
        everySuccess => _every,
        confirmAndFault => _confirm,
        dailyDigest => _digest,
      };

  static AutoBookNotifyMode parse(String? raw) => switch (raw) {
        _confirm => confirmAndFault,
        _digest => dailyDigest,
        _ => everySuccess,
      };
}

// ───────────────────────── 目标解析(B2) ─────────────────────────

/// 自动目标的解析状态(B0 §3.3)。
enum AutoBookTargetState {
  /// 目标有效,按冻结/配置解析出本地账本。
  resolved,

  /// 已迁移但用户尚未确认:保持旧兼容路径(浏览账本口径)。
  unconfirmed,

  /// 目标失效(账本被删/权限撤销/scope 不匹配):**停止自动写入**,提示修复。
  invalid,

  /// 目标待确定(没有任何可用账本/配置不可读):等待用户确定后绑定一次。
  undetermined,
}

/// 一次目标解析的结果:事件持久化与识别入账共用同一快照。
class AutoBookTargetResolution {
  const AutoBookTargetResolution({
    required this.state,
    this.ledgerId,
    this.targetRef,
    this.configVersion = 0,
    this.reason,
  });

  final AutoBookTargetState state;
  final int? ledgerId;

  /// 稳定引用 `syncId:<v>` / `localId:<v>`;null = 无法表达(待确定)。
  final String? targetRef;
  final int configVersion;

  /// 失效/待确定的原因码(事件 reason 用),不含任何原文。
  final String? reason;

  bool get canWrite =>
      state == AutoBookTargetState.resolved ||
      state == AutoBookTargetState.unconfirmed;

  String get stateName => switch (state) {
        AutoBookTargetState.resolved => 'resolved',
        AutoBookTargetState.unconfirmed => 'unconfirmed',
        AutoBookTargetState.invalid => 'invalid',
        AutoBookTargetState.undetermined => 'undetermined',
      };
}

/// 账本 → 稳定引用(B0 §3.2:优先 syncId,无 syncId 的本地账本用 localId)。
String autoBookTargetRefFor(schema.Ledger ledger) {
  final syncId = (ledger.syncId ?? '').trim();
  return syncId.isEmpty ? 'localId:${ledger.id}' : 'syncId:$syncId';
}

/// 原生队列项里冻结的目标快照(B2:捕获时由 [AutoBookTargetStore] 写入)。
///
/// 字段缺失(旧队列 / 原生缓存未就绪)时全部为 null,调用方回落到当前配置。
class AutoBookQueueTargetSnapshot {
  const AutoBookQueueTargetSnapshot({this.ref, this.state, this.version});

  final String? ref;
  final String? state;
  final int? version;

  factory AutoBookQueueTargetSnapshot.fromQueueItem(Object? item) {
    if (item is! Map) return const AutoBookQueueTargetSnapshot();
    String? asString(Object? v) {
      final text = (v ?? '').toString().trim();
      return text.isEmpty ? null : text;
    }

    return AutoBookQueueTargetSnapshot(
      ref: asString(item['targetRef']),
      state: asString(item['targetState']),
      version: int.tryParse((item['targetVersion'] ?? '').toString()),
    );
  }
}

/// 只有「user:」作用域才做账号隔离:设备本地目标不因登录/登出失效,
/// 但 user 作用域目标必须与当前账号完全一致(B0 §3.2 的细化)。
bool autoBookScopeMatches(String targetScope, String currentScope) {
  if (!targetScope.startsWith('user:')) return true;
  return targetScope == currentScope;
}

/// 按稳定引用解析本地账本 id;找不到返回 null(=失效)。
int? resolveLedgerIdByRef(String ref, List<schema.Ledger> ledgers) {
  final idx = ref.indexOf(':');
  if (idx <= 0) return null;
  final kind = ref.substring(0, idx);
  final value = ref.substring(idx + 1);
  if (value.isEmpty) return null;
  if (kind == 'localId') {
    final id = int.tryParse(value);
    if (id == null) return null;
    for (final ledger in ledgers) {
      if (ledger.id == id) return ledger.id;
    }
    return null;
  }
  if (kind == 'syncId') {
    for (final ledger in ledgers) {
      if ((ledger.syncId ?? '') == value) return ledger.id;
    }
    return null;
  }
  return null;
}

/// 纯函数版目标解析(可单测,不碰 IO)。
///
/// 优先级:冻结引用 > 已确认目标 > 迁移未确认目标(旧兼容路径) > 无目标。
AutoBookTargetResolution resolveAutoBookTargetPure({
  required AutomationSettings settings,
  required List<schema.Ledger> ledgers,
  required int? legacyLedgerId,
  required String currentScope,
  String? frozenRef,
  String? frozenState,
  int? frozenConfigVersion,
}) {
  final version = frozenConfigVersion ?? settings.configVersion;

  // 捕获时冻结的快照优先(B0 §3.3):后续改设置不改已捕获事件的目标。
  if (frozenRef != null && frozenRef.isNotEmpty) {
    if (frozenState == 'undetermined') {
      return AutoBookTargetResolution(
        state: AutoBookTargetState.undetermined,
        targetRef: frozenRef,
        configVersion: version,
        reason: 'target_undetermined',
      );
    }
    final ledgerId = resolveLedgerIdByRef(frozenRef, ledgers);
    if (ledgerId == null) {
      return AutoBookTargetResolution(
        state: AutoBookTargetState.invalid,
        targetRef: frozenRef,
        configVersion: version,
        reason: 'target_ledger_missing',
      );
    }
    return AutoBookTargetResolution(
      state: AutoBookTargetState.resolved,
      ledgerId: ledgerId,
      targetRef: frozenRef,
      configVersion: version,
    );
  }

  final target = settings.target;
  if (target == null) {
    // 尚未迁移:按旧口径给出一次性的兜底;没有任何账本则待确定。
    if (legacyLedgerId == null) {
      return const AutoBookTargetResolution(
        state: AutoBookTargetState.undetermined,
        reason: 'target_undetermined',
      );
    }
    schema.Ledger? legacy;
    for (final l in ledgers) {
      if (l.id == legacyLedgerId) legacy = l;
    }
    return AutoBookTargetResolution(
      state: AutoBookTargetState.unconfirmed,
      ledgerId: legacyLedgerId,
      targetRef: legacy == null ? null : autoBookTargetRefFor(legacy),
      configVersion: version,
      reason: 'target_unconfirmed',
    );
  }

  final ref = '${target.kind}:${target.value}';
  if (!autoBookScopeMatches(target.scope, currentScope)) {
    return AutoBookTargetResolution(
      state: AutoBookTargetState.invalid,
      targetRef: ref,
      configVersion: version,
      reason: 'target_scope_mismatch',
    );
  }

  final ledgerId = resolveLedgerIdByRef(ref, ledgers);
  if (ledgerId == null) {
    return AutoBookTargetResolution(
      state: AutoBookTargetState.invalid,
      targetRef: ref,
      configVersion: version,
      reason: 'target_ledger_missing',
    );
  }

  if (!target.confirmed) {
    // 已迁移未确认:保持旧兼容路径(浏览账本),不因迁移就改用户行为。
    return AutoBookTargetResolution(
      state: AutoBookTargetState.unconfirmed,
      ledgerId: legacyLedgerId ?? ledgerId,
      targetRef: ref,
      configVersion: version,
      reason: 'target_unconfirmed',
    );
  }

  return AutoBookTargetResolution(
    state: AutoBookTargetState.resolved,
    ledgerId: ledgerId,
    targetRef: ref,
    configVersion: version,
  );
}

/// 旧口径的账本解析(B2 之前的 `_resolveLedgerId`),迁移与未确认时使用。
Future<int?> resolveLegacyLedgerId(ProviderContainer container) async {
  try {
    return container.read(currentLedgerIdProvider);
  } catch (_) {}
  final prefs = await SharedPreferences.getInstance();
  final fromPrefs = prefs.getInt('current_ledger_id');
  if (fromPrefs != null) return fromPrefs;
  try {
    final ledgers = await container.read(repositoryProvider).getAllLedgers();
    if (ledgers.isEmpty) return null;
    await prefs.setInt('current_ledger_id', ledgers.first.id);
    return ledgers.first.id;
  } catch (_) {
    return null;
  }
}

/// 当前账号作用域(B0 §3.2):无稳定 userId 时回 'local'(仅本机)。
Future<String> currentAutomationUserScope(ProviderContainer container) async {
  try {
    final auth = await container.read(authServiceProvider.future);
    final user = await auth.currentUser;
    if (user != null && user.id.isNotEmpty) return 'user:${user.id}';
  } catch (_) {}
  return 'local';
}

/// 目标解析入口(自动四路 drain / 重放共用)。
///
/// [frozenRef]/[frozenState] 来自捕获时写入队列项的快照;缺省时用当前配置,
/// 并在首次运行时把旧口径账本**一次性**迁移成未确认目标(B0 §3.4)。
Future<AutoBookTargetResolution> resolveAutoBookTarget(
  ProviderContainer container, {
  String? frozenRef,
  String? frozenState,
  int? frozenConfigVersion,
}) async {
  final store = AutomationSettingsStore();
  var settings = await store.load();
  final scope = await currentAutomationUserScope(container);

  List<schema.Ledger> ledgers;
  try {
    ledgers = await container.read(repositoryProvider).getAllLedgers();
  } catch (_) {
    ledgers = const [];
  }
  final legacyLedgerId = await resolveLegacyLedgerId(container);

  // 一次性迁移:把「当时有效的账本」冻成未确认目标,只写一次。
  if (settings.target == null && legacyLedgerId != null) {
    schema.Ledger? ledger;
    for (final l in ledgers) {
      if (l.id == legacyLedgerId) ledger = l;
    }
    if (ledger != null) {
      final syncId = (ledger.syncId ?? '').trim();
      settings = await store.bumpVersion(settings.copyWith(
        target: AutoBookTarget(
          scope: scope,
          kind: syncId.isEmpty ? 'localId' : 'syncId',
          value: syncId.isEmpty ? '${ledger.id}' : syncId,
          migratedFrom: 'legacy_current_ledger',
        ),
      ));
    }
  }

  return resolveAutoBookTargetPure(
    settings: settings,
    ledgers: ledgers,
    legacyLedgerId: legacyLedgerId,
    currentScope: scope,
    frozenRef: frozenRef,
    frozenState: frozenState,
    frozenConfigVersion: frozenConfigVersion,
  );
}

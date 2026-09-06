import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_provider_config.dart';
import 'ai_constants.dart';
import 'ai_provider_factory.dart';
import '../relay/ai_relay_client.dart';
import '../../services/system/logger_service.dart';

/// AI 服务商管理服务
///
/// **服务端为准 + 本地掩码缓存**:自「LLM 经服务端中转」改造后,API Key 只存
/// 服务端(`UserProfile.ai_config_json`),本类只在本地 SharedPreferences 缓存
/// 服务端列表的**掩码视图**(`apiKey` 字段是 `****+末4位`)。所有增删改
/// ([addProvider] / [updateProvider] / [deleteProvider] / 能力绑定)都调服务端
/// `/ai/providers`,成功后回读刷新缓存;本地不再产生任何真 key。
///
/// [serverApi] 由 sync_providers 启动时注入;未注入(云服务未配置)时变更操作
/// 抛 [AIException],查询照常走本地缓存(空缓存 = 未配置)。
///
/// [onConfigChanged] 语义收窄:只代表「custom_prompt / strategy / 开关等
/// 非敏感 prefs」变了,由 sync_providers 推到 server;providers/binding 不再
/// 走 profile 同步(密钥不上行)。
class AIProviderManager {
  static const String _tag = 'AIProviderManager';
  static const String _keyProviders = 'ai_providers_v2';
  static const String _keyBinding = 'ai_capability_binding_v2';
  // 一次性迁移标记:直连时代本地存过真 key,登录后把遗留配置推上服务端。
  static const String _keyLegacyMigrated = 'ai_providers_migrated_to_server_v1';

  /// 全局回调:custom_prompt / strategy / 语音开关等非敏感 prefs 变更时触发,
  /// sync_providers 启动时注入"推 AI prefs 到 server"的实现。fire-and-forget。
  static void Function()? onConfigChanged;

  /// 服务端配置 API。sync_providers 启动时注入;null = 云服务未配置。
  static AiRelayClient? serverApi;

  /// 保存自定义提示词。跟其它 prefs 同套路,走统一的 onConfigChanged。
  static Future<void> saveCustomPrompt(String prompt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_custom_prompt', prompt);
    try {
      onConfigChanged?.call();
    } catch (e, st) {
      logger.warning(_tag, 'onConfigChanged 触发失败: $e', st);
    }
  }

  /// 生成简单的唯一ID
  static String _generateId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(999999).toString().padLeft(6, '0');
    return 'provider_${timestamp}_$random';
  }

  // ============================================================
  // 查询(本地掩码缓存)
  // ============================================================

  /// 获取所有服务商配置(本地缓存;apiKey 为掩码)。
  static Future<List<AIServiceProviderConfig>> getProviders() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyProviders);

    if (jsonStr == null || jsonStr.isEmpty) {
      // 首次使用，尝试从旧配置迁移
      await migrateFromOldConfig();

      // 迁移后重新读取
      final migratedStr = prefs.getString(_keyProviders);
      if (migratedStr == null || migratedStr.isEmpty) {
        // 如果迁移后仍为空，初始化默认服务商
        final defaultProviders = [AIServiceProviderConfig.zhipuDefault];
        await _saveCache(defaultProviders);
        return defaultProviders;
      }
      // 迁移成功，继续解析
      return _parseProviders(migratedStr);
    }

    return _parseProviders(jsonStr);
  }

  /// 解析服务商缓存 JSON
  static Future<List<AIServiceProviderConfig>> _parseProviders(
      String jsonStr) async {
    try {
      final jsonList = jsonDecode(jsonStr) as List;
      var providers = jsonList
          .map((e) =>
              AIServiceProviderConfig.fromJson(e as Map<String, dynamic>))
          .toList();

      // 确保智谱GLM始终存在
      if (!providers.any((p) => p.id == 'zhipu_glm')) {
        providers.insert(0, AIServiceProviderConfig.zhipuDefault);
        await _saveCache(providers);
      }

      return providers;
    } catch (e, st) {
      logger.error(_tag, '解析服务商配置失败', e, st);
      return [AIServiceProviderConfig.zhipuDefault];
    }
  }

  /// 获取单个服务商配置
  static Future<AIServiceProviderConfig?> getProvider(String id) async {
    final providers = await getProviders();
    try {
      return providers.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 获取能力绑定配置
  static Future<AICapabilityBinding> getCapabilityBinding() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyBinding);

    if (jsonStr == null || jsonStr.isEmpty) {
      return AICapabilityBinding.defaultBinding;
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return AICapabilityBinding.fromJson(json);
    } catch (e, st) {
      logger.error(_tag, '解析能力绑定失败', e, st);
      return AICapabilityBinding.defaultBinding;
    }
  }

  /// 获取指定能力的服务商配置
  static Future<AIServiceProviderConfig?> getProviderForCapability(
    AICapabilityType type,
  ) async {
    final binding = await getCapabilityBinding();
    String? providerId;

    switch (type) {
      case AICapabilityType.text:
        providerId = binding.textProviderId;
        break;
      case AICapabilityType.vision:
        providerId = binding.visionProviderId;
        break;
      case AICapabilityType.speech:
        providerId = binding.speechProviderId;
        break;
    }

    if (providerId == null) {
      return AIServiceProviderConfig.zhipuDefault;
    }

    return await getProvider(providerId);
  }

  /// 指定能力对应的 provider 是否已配置好(服务端有 key,本地体现为掩码非空)。
  /// v3.2.1 删 OCR 后,图片/语音记账完全依赖 AI,UI 调用前先检查,未配置直接
  /// 提示用户去 AI 设置页,避免 vision()/speechToText() 内部抛异常用户看不懂。
  ///
  /// M1-1:这里**只表达配置存在**,不代表运行时可调用。冷启动时本地配置缓存
  /// 有效而 `AiRelayClient` 尚未注入的窗口内它同样返回 true。自动入口要判断
  /// 「现在能不能调」必须另看 `AiRuntimeCoordinator.instance`。
  static Future<bool> isCapabilityConfigured(AICapabilityType type) async {
    final provider = await getProviderForCapability(type);
    return provider != null && provider.isValid;
  }

  // ============================================================
  // 变更(服务端为准,成功后回读缓存)
  // ============================================================

  static AiRelayClient _requireServerApi() {
    final api = serverApi;
    if (api == null) {
      throw AIException('需要登录并配置智记云服务后才能管理 AI 服务商');
    }
    return api;
  }

  /// 添加服务商
  static Future<AIServiceProviderConfig> addProvider({
    required String name,
    required String apiKey,
    required String baseUrl,
    String textModel = '',
    String visionModel = '',
    String audioModel = '',
  }) async {
    final newProvider = AIServiceProviderConfig(
      id: _generateId(),
      name: name,
      isBuiltIn: false,
      apiKey: apiKey,
      baseUrl: baseUrl,
      textModel: textModel,
      visionModel: visionModel,
      audioModel: audioModel,
      createdAt: DateTime.now(),
    );
    await _requireServerApi().createProvider(newProvider);
    await refreshFromServer();
    logger.info(_tag, '添加服务商: ${newProvider.name}');
    return newProvider;
  }

  /// 直接添加服务商配置（保留原始 ID，用于配置导入）。
  /// 导入文件里来自新版本的 apiKey 是掩码 —— 掩码不算真 key,置空后由
  /// 服务端按 id 决定保留与否;旧版本导出的真 key 则原样上传。
  static Future<void> addProviderWithConfig(
      AIServiceProviderConfig provider) async {
    final key = provider.apiKey;
    final upload = AIProviderFactory.isMaskedApiKey(key)
        ? provider.copyWith(apiKey: '')
        : provider;
    await _requireServerApi().createProvider(upload);
    await refreshFromServer();
    logger.info(_tag, '导入服务商: ${provider.name} (ID: ${provider.id})');
  }

  /// 更新服务商。[provider.apiKey] 为掩码 / 空 = 服务端保留原 key。
  static Future<void> updateProvider(AIServiceProviderConfig provider) async {
    await _requireServerApi().updateProvider(provider);
    await refreshFromServer();
    logger.info(_tag, '更新服务商: ${provider.name}');
  }

  /// 删除服务商
  static Future<bool> deleteProvider(String id) async {
    final provider = await getProvider(id);

    // 内置服务商不可删除
    if (provider == null || provider.isBuiltIn) {
      logger.warning(_tag, '无法删除内置服务商');
      return false;
    }

    await _requireServerApi().deleteProvider(id);
    await refreshFromServer();
    // 服务端删除后已把相关能力重绑到内置智谱,缓存随回读一并更新。
    logger.info(_tag, '删除服务商: ${provider.name}');
    return true;
  }

  /// 保存能力绑定配置(服务端 PUT /ai/providers/binding)。
  static Future<void> saveCapabilityBinding(AICapabilityBinding binding) async {
    await _requireServerApi().updateBinding(binding);
    await refreshFromServer();
    logger.info(_tag,
        '保存能力绑定: text=${binding.textProviderId}, vision=${binding.visionProviderId}, speech=${binding.speechProviderId}');
  }

  /// 设置单个能力的服务商
  static Future<void> setCapabilityProvider(
    AICapabilityType type,
    String providerId,
  ) async {
    final binding = await getCapabilityBinding();
    AICapabilityBinding newBinding;

    switch (type) {
      case AICapabilityType.text:
        newBinding = binding.copyWith(textProviderId: providerId);
        break;
      case AICapabilityType.vision:
        newBinding = binding.copyWith(visionProviderId: providerId);
        break;
      case AICapabilityType.speech:
        newBinding = binding.copyWith(speechProviderId: providerId);
        break;
    }

    await saveCapabilityBinding(newBinding);
  }

  // ============================================================
  // 服务端同步
  // ============================================================

  /// 从服务端拉服务商列表(掩码) + 能力绑定,写入本地缓存。静默失败:
  /// 云服务未注入 / 网络异常都只打日志,不影响 UI 用旧缓存。
  ///
  /// 首次拉取时若服务端还没有任何服务商,而本地遗留了直连时代的真 key,
  /// 会把它们(含能力绑定)一次性推上服务端 —— 旧版本升级到中转架构后
  /// 密钥不丢。
  static Future<void> refreshFromServer() async {
    final api = serverApi;
    if (api == null) return;
    try {
      var (providers, binding) = await api.listProviders();
      final prefs = await SharedPreferences.getInstance();

      if (providers.isEmpty && !(prefs.getBool(_keyLegacyMigrated) ?? false)) {
        await prefs.setBool(_keyLegacyMigrated, true);
        final locals = await getProviders();
        final legacy = locals
            .where((p) => !AIProviderFactory.isMaskedApiKey(p.apiKey))
            .toList();
        if (legacy.isNotEmpty) {
          logger.info(_tag, '迁移直连时代的本地服务商配置到服务端: ${legacy.length} 个');
          for (final p in legacy) {
            try {
              await api.createProvider(p);
            } catch (e) {
              // 重复 id 等 → 跳过单个,继续迁移其余
              logger.warning(_tag, '迁移服务商 ${p.name} 失败(跳过): $e');
            }
          }
          try {
            await api.updateBinding(await getCapabilityBinding());
          } catch (e) {
            logger.warning(_tag, '迁移能力绑定失败: $e');
          }
          (providers, binding) = await api.listProviders();
        }
      }

      await prefs.setString(
          _keyProviders, jsonEncode(providers.map((p) => p.toJson()).toList()));
      await prefs.setString(_keyBinding, jsonEncode(binding.toJson()));
      logger.info(_tag, '已从服务端刷新 AI 服务商缓存: ${providers.length} 个');
    } catch (e, st) {
      logger.warning(_tag, '从服务端刷新 AI 服务商失败: $e', st);
    }
  }

  // ============================================================
  // prefs 同步(custom_prompt / strategy / 开关;不再含 providers/binding)
  // ============================================================

  /// 当前 AI prefs 的快照,推给 server 同步到另一端。
  /// **密钥不走这里**:providers/binding 已由服务端持有,带上掩码回传只会
  /// 徒增体积(server 合并时会保留原值,但没必要)。
  static Future<Map<String, dynamic>> snapshotForSync() async {
    final prefs = await SharedPreferences.getInstance();
    final snapshot = <String, dynamic>{
      'custom_prompt': prefs.getString('ai_custom_prompt') ?? '',
      'strategy': prefs.getString('ai_strategy') ?? '',
      'bill_extraction_enabled':
          prefs.getBool('ai_bill_extraction_enabled') ?? false,
      'use_vision': prefs.getBool('ai_use_vision') ?? false,
    };
    // 语音设置仅在本机曾显式配置时才携带。server 端 ai_config 是整包替换
    // (providers 段合并保留),若未设置端携带空值回推,会清空他机配好的语音设置。
    if (prefs.containsKey(AIConstants.keyVoiceTriggerMode)) {
      snapshot['voice_trigger_mode'] =
          prefs.getString(AIConstants.keyVoiceTriggerMode);
    }
    if (prefs.containsKey(AIConstants.keyVoiceSilenceTimeoutMs)) {
      snapshot['voice_silence_timeout_ms'] =
          prefs.getInt(AIConstants.keyVoiceSilenceTimeoutMs);
    }
    return snapshot;
  }

  /// 把 server /profile/me 返回的 ai_config dict 落到本地 SharedPreferences。
  /// providers/binding 段**忽略** —— 它们由 [refreshFromServer] 经 /ai/providers
  /// 掩码下发,真 key 永不下行,这里也不能拿掩码覆盖本地缓存以外的语义。
  static Future<void> applyFromServer(Map<String, dynamic> config) async {
    final prefs = await SharedPreferences.getInstance();

    final prompt = config['custom_prompt'] as String?;
    if (prompt != null && prefs.getString('ai_custom_prompt') != prompt) {
      await prefs.setString('ai_custom_prompt', prompt);
    }

    final strategy = config['strategy'] as String?;
    if (strategy != null &&
        strategy.isNotEmpty &&
        prefs.getString('ai_strategy') != strategy) {
      await prefs.setString('ai_strategy', strategy);
    }

    final billEnabled = config['bill_extraction_enabled'] as bool?;
    if (billEnabled != null &&
        prefs.getBool('ai_bill_extraction_enabled') != billEnabled) {
      await prefs.setBool('ai_bill_extraction_enabled', billEnabled);
    }

    final useVision = config['use_vision'] as bool?;
    if (useVision != null && prefs.getBool('ai_use_vision') != useVision) {
      await prefs.setBool('ai_use_vision', useVision);
    }

    // 语音触发方式 / 静音阈值（仅当与本地不同才写，避免触发同步回环）
    final voiceTriggerMode = config['voice_trigger_mode'] as String?;
    if (voiceTriggerMode != null &&
        voiceTriggerMode.isNotEmpty &&
        prefs.getString(AIConstants.keyVoiceTriggerMode) != voiceTriggerMode) {
      await prefs.setString(AIConstants.keyVoiceTriggerMode, voiceTriggerMode);
    }
    final voiceSilenceTimeout =
        (config['voice_silence_timeout_ms'] as num?)?.toInt();
    if (voiceSilenceTimeout != null &&
        prefs.getInt(AIConstants.keyVoiceSilenceTimeoutMs) !=
            voiceSilenceTimeout) {
      await prefs.setInt(
          AIConstants.keyVoiceSilenceTimeoutMs, voiceSilenceTimeout);
    }
    logger.info(_tag, 'AI prefs 已从 server 应用到本地');
  }

  // ============================================================
  // 本地缓存写入(静默,不触发 onConfigChanged)
  // ============================================================

  /// 保存服务商列表缓存。变更走服务端后由 [refreshFromServer] 回读,这里只
  /// 供缓存初始化/迁移使用。
  static Future<void> _saveCache(
      List<AIServiceProviderConfig> providers) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(providers.map((p) => p.toJson()).toList());
    await prefs.setString(_keyProviders, jsonStr);
  }

  /// 迁移旧配置到新格式(本地缓存 bootstrap,与密钥无关)
  static Future<void> migrateFromOldConfig() async {
    final prefs = await SharedPreferences.getInstance();

    // 检查是否已迁移
    if (prefs.containsKey(_keyProviders)) {
      return;
    }

    logger.info(_tag, '开始迁移旧配置');

    // 读取旧配置 - 使用 AIConstants 中定义的 key
    final oldProvider = prefs.getString('ai_service_provider') ?? 'zhipuGLM';
    final isCustom = oldProvider == 'custom';

    // 读取智谱 GLM 配置（使用正确的 key）
    final glmApiKey = prefs.getString('ai_glm_api_key') ?? '';
    final glmTextModel = prefs.getString('ai_glm_model') ?? 'glm-4-flash';
    final glmVisionModel =
        prefs.getString('ai_glm_vision_model') ?? 'glm-4v-flash';
    final glmAudioModel =
        prefs.getString('ai_glm_audio_model') ?? 'glm-4-voice';

    logger.info(_tag, '迁移智谱配置: apiKey=${glmApiKey.isNotEmpty ? "已配置" : "未配置"}');

    final providers = <AIServiceProviderConfig>[
      // 智谱GLM（从旧配置读取 API Key）
      AIServiceProviderConfig.zhipuDefault.copyWith(
        apiKey: glmApiKey,
        textModel: glmTextModel,
        visionModel: glmVisionModel,
        audioModel: glmAudioModel,
      ),
    ];

    // 如果有自定义服务商配置，也迁移过来（使用正确的 key）
    final customApiKey = prefs.getString('ai_custom_api_key') ?? '';
    final customBaseUrl = prefs.getString('ai_custom_base_url') ?? '';
    if (customApiKey.isNotEmpty && customBaseUrl.isNotEmpty) {
      providers.add(AIServiceProviderConfig(
        id: 'custom_migrated',
        name: '自定义服务商',
        apiKey: customApiKey,
        baseUrl: customBaseUrl,
        textModel: prefs.getString('ai_custom_text_model') ?? '',
        visionModel: prefs.getString('ai_custom_vision_model') ?? '',
        audioModel: prefs.getString('ai_custom_audio_model') ?? '',
        createdAt: DateTime.now(),
      ));
      logger.info(_tag, '迁移自定义服务商配置');
    }

    await _saveCache(providers);

    // 设置能力绑定
    final defaultProviderId =
        isCustom && customApiKey.isNotEmpty ? 'custom_migrated' : 'zhipu_glm';

    final binding = AICapabilityBinding(
      textProviderId: defaultProviderId,
      visionProviderId: defaultProviderId,
      speechProviderId: defaultProviderId,
    );
    final jsonStr = jsonEncode(binding.toJson());
    if (!prefs.containsKey(_keyBinding)) {
      await prefs.setString(_keyBinding, jsonStr);
    }

    logger.info(_tag, '配置迁移完成');
  }
}

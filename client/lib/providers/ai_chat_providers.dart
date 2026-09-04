import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart';

import '../ai/core/ai_extraction_engine.dart';
import '../services/ai/ai_bookkeeper.dart';
import '../services/ai/ai_call_reporter.dart';
import '../services/ai/ai_chat_service.dart';
import '../services/billing/bill_creation_service.dart';
import '../providers.dart';
import '../data/db.dart';

/// AI 多模态记账底座 (Layer 1)。无状态,可全局复用。
final aiExtractionEngineProvider = Provider<AiExtractionEngine>(
  (ref) => const DefaultAiExtractionEngine(),
);

/// AI 调用记录上报器 —— 把 App 本地 AI 记账调用(通知/短信/截图/对话/语音)
/// 上报服务端 `ai_analysis_logs`,让 Web「AI 调用记录」页与 App 共用数据。
/// SmartBook Cloud 未配置或未登录时返回 null(不上报,零影响)。
final aiCallReporterProvider = Provider<AiCallReporter?>((ref) {
  final async = ref.watch(smartbookCloudProviderInstance);
  final provider = async.value;
  if (provider == null) return null;
  final auth = provider.auth;
  // SmartBook provider 的 auth 就是 SmartBookCloudAuthService(见
  // smartbook_cloud_provider.initialize);其它 auth 实现没有 token 获取接口,
  // 不上报。
  if (auth is! SmartBookCloudAuthService) return null;
  return AiCallReporterHttp(
    baseUrl: provider.baseUrl ?? '',
    apiPrefix: provider.apiPrefix ?? '/api/v1',
    accessToken: () => auth.requireAccessToken(),
  );
});

/// AI 记账应用层 (Layer 2)。5 个调用渠道(对话/图片/语音/自动截图/自动文本)
/// 的统一入口。
final aiBookkeeperProvider = Provider<AiBookkeeper>((ref) {
  final repo = ref.watch(repositoryProvider);
  return AiBookkeeper(
    repository: repo,
    engine: ref.watch(aiExtractionEngineProvider),
    persister: BillCreationService(
      repo,
      // 多币种(.docs/multi-currency-ai A6):AI 识别出外币时,落库前把该币种
      // 的汇率拉到本地,否则 repo 只能按 1:1 折算。注入而非在渠道层预拉,是
      // 为了让**后台自动记账**(截图/通知,无 WidgetRef)也走同一条路径。
      ensureRate: (code) =>
          refreshExchangeRates(ref, force: true, extraQuotes: {code}),
    ),
    reporter: ref.watch(aiCallReporterProvider),
  );
});

/// AI 对话服务 Provider
final aiChatServiceProvider = Provider<AIChatService>((ref) {
  final repo = ref.watch(repositoryProvider);
  return AIChatService(
    repo: repo,
    bookkeeper: ref.watch(aiBookkeeperProvider),
  );
});

/// 当前对话 ID Provider
final currentConversationIdProvider = StateProvider<int?>((ref) => null);

/// 消息列表 Provider
final messagesProvider = StreamProvider.family<List<Message>, int>(
  (ref, conversationId) {
    final repo = ref.watch(repositoryProvider);
    return repo.watchMessages(conversationId);
  },
);

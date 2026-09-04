import '../db.dart';

/// AI 对话和消息数据仓库接口
abstract class AIRepository {
  // ============================================
  // Conversation 会话操作
  // ============================================

  /// 查询全局活跃对话（不限制账本）
  Future<Conversation?> getActiveConversation();

  /// 根据 ID 获取会话
  Future<Conversation?> getConversationById(int id);

  /// 创建新会话
  Future<int> createConversation(ConversationsCompanion conversation);

  /// 更新会话
  Future<void> updateConversation(Conversation conversation);

  /// 删除会话
  Future<void> deleteConversation(int id);

  // ============================================
  // Message 消息操作
  // ============================================

  /// 获取会话的所有消息
  Stream<List<Message>> watchMessages(int conversationId);

  /// 获取单条消息
  Future<Message?> getMessageById(int id);

  /// 创建消息
  Future<int> createMessage(MessagesCompanion message);

  /// 更新消息
  Future<void> updateMessage(Message message);

  /// 删除会话的所有消息
  Future<void> deleteMessagesByConversation(int conversationId);

  /// 删除单条消息
  Future<void> deleteMessage(int id);

  /// 根据交易ID获取消息
  Future<Message?> getMessageByTransactionId(int transactionId);
}

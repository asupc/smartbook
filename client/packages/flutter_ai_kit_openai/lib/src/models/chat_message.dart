import 'package:json_annotation/json_annotation.dart';

part 'chat_message.g.dart';

/// Chat 消息
@JsonSerializable()
class ChatMessage {
  /// 角色：system, user, assistant
  final String role;

  /// 内容：String 或 List<Map>（多模态）
  final dynamic content;

  ChatMessage({
    required this.role,
    required this.content,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageFromJson(json);

  Map<String, dynamic> toJson() => _$ChatMessageToJson(this);

  /// 创建用户消息
  factory ChatMessage.user(String content) => ChatMessage(
        role: 'user',
        content: content,
      );

  /// 创建系统消息
  factory ChatMessage.system(String content) => ChatMessage(
        role: 'system',
        content: content,
      );

  /// 创建助手消息
  factory ChatMessage.assistant(String content) => ChatMessage(
        role: 'assistant',
        content: content,
      );

  /// 创建多模态消息（文本 + 图片）
  factory ChatMessage.multimodal({
    required String text,
    required String base64Image,
    String role = 'user',
  }) =>
      ChatMessage(
        role: role,
        content: [
          {'type': 'text', 'text': text},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/jpeg;base64,$base64Image',
            },
          },
        ],
      );
}

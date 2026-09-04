import 'package:json_annotation/json_annotation.dart';
import 'chat_message.dart';

part 'chat_request.g.dart';

/// Chat API 请求
@JsonSerializable()
class ChatRequest {
  /// 模型名称
  final String model;

  /// 消息列表
  final List<ChatMessage> messages;

  /// 温度参数（0-1，越大越随机）
  final double temperature;

  /// 最大 token 数
  @JsonKey(name: 'max_tokens')
  final int? maxTokens;

  /// Top P 采样
  @JsonKey(name: 'top_p')
  final double? topP;

  /// 流式响应
  final bool? stream;

  ChatRequest({
    required this.model,
    required this.messages,
    this.temperature = 0.1,
    this.maxTokens,
    this.topP,
    this.stream,
  });

  factory ChatRequest.fromJson(Map<String, dynamic> json) =>
      _$ChatRequestFromJson(json);

  Map<String, dynamic> toJson() => _$ChatRequestToJson(this);
}

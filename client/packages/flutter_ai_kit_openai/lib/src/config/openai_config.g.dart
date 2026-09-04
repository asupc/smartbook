// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'openai_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

OpenAIConfig _$OpenAIConfigFromJson(Map<String, dynamic> json) => OpenAIConfig(
      baseUrl: json['baseUrl'] as String,
      apiKey: json['apiKey'] as String,
      defaultModel: json['defaultModel'] as String? ?? 'gpt-4o-mini',
      textModel: json['textModel'] as String?,
      visionModel: json['visionModel'] as String?,
      audioModel: json['audioModel'] as String?,
      timeout: (json['timeout'] as num?)?.toInt() ?? 60,
      enableLogging: json['enableLogging'] as bool? ?? false,
      proxy: json['proxy'] as String?,
    );

Map<String, dynamic> _$OpenAIConfigToJson(OpenAIConfig instance) =>
    <String, dynamic>{
      'baseUrl': instance.baseUrl,
      'apiKey': instance.apiKey,
      'defaultModel': instance.defaultModel,
      'textModel': instance.textModel,
      'visionModel': instance.visionModel,
      'audioModel': instance.audioModel,
      'timeout': instance.timeout,
      'enableLogging': instance.enableLogging,
      'proxy': instance.proxy,
    };

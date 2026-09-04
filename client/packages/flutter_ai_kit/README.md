# Flutter AI Kit

A universal AI capability kit for Flutter supporting local models and cloud APIs.

## Features

- ✅ **Provider-agnostic**: Support any local model (TFLite, ONNX) or cloud API
- ✅ **Strategy-based execution**: Local-first, cloud-first, local-only, cloud-only, cost-optimized, custom priority
- ✅ **Type-safe**: Generic task and result types
- ✅ **Extensible**: Easy to add new providers and strategies
- ✅ **Lightweight**: Core package has minimal dependencies
- ✅ **Smart fallback**: Automatic fallback to alternative providers on failure

## Installation

```yaml
dependencies:
  flutter_ai_kit:
    path: packages/flutter_ai_kit
```

## Quick Start

### 1. Define your task

```dart
import 'package:flutter_ai_kit/flutter_ai_kit.dart';

class TextExtractionTask extends AITask<String, Map<String, dynamic>> {
  @override
  String get taskType => 'text_extraction';

  @override
  final String input;

  TextExtractionTask(this.input);

  @override
  Map<String, dynamic> toJson() => {'text': input};
}
```

### 2. Create a provider

```dart
class MyCloudProvider implements AIProvider<String, Map<String, dynamic>> {
  @override
  String get id => 'my_cloud_provider';

  @override
  String get name => 'My Cloud Provider';

  @override
  AIProviderType get type => AIProviderType.cloud;

  @override
  bool get requiresNetwork => true;

  @override
  bool supportsTask(String taskType) => taskType == 'text_extraction';

  @override
  Future<bool> isReady() async => true;

  @override
  Future<AIResult<Map<String, dynamic>>> execute(
    AITask<String, Map<String, dynamic>> task,
  ) async {
    final startTime = DateTime.now();

    try {
      // Your API call logic here
      final result = await callMyAPI(task.input);

      return AIResult.success(
        result,
        DateTime.now().difference(startTime),
        metadata: AIResultMetadata(providerName: name),
      );
    } catch (e) {
      return AIResult.failure(
        e.toString(),
        DateTime.now().difference(startTime),
        metadata: AIResultMetadata(providerName: name),
      );
    }
  }

  @override
  Future<double> estimateCost(
    AITask<String, Map<String, dynamic>> task,
  ) async => 0.0;
}
```

### 3. Use FlutterAIKit

```dart
void main() async {
  final aiKit = FlutterAIKit();

  // Register providers
  aiKit.registerProvider(MyCloudProvider());

  // Set execution strategy
  aiKit.setStrategy(LocalFirstStrategy());

  // Execute task
  final task = TextExtractionTask('your input text');
  final result = await aiKit.execute(task);

  if (result.success) {
    print('Result: ${result.data}');
    print('Provider: ${result.metadata.providerName}');
    print('Duration: ${result.duration.inMilliseconds}ms');
  } else {
    print('Error: ${result.error}');
  }
}
```

## Execution Strategies

### LocalFirstStrategy (Recommended)

Tries local providers first, falls back to cloud on failure.

```dart
aiKit.setStrategy(LocalFirstStrategy());
```

### CloudFirstStrategy

Tries cloud providers first, falls back to local on failure.

```dart
aiKit.setStrategy(CloudFirstStrategy());
```

### LocalOnlyStrategy

Only uses local providers. Good for privacy-sensitive scenarios.

```dart
aiKit.setStrategy(LocalOnlyStrategy());
```

### CloudOnlyStrategy

Only uses cloud providers. Good for avoiding model downloads.

```dart
aiKit.setStrategy(CloudOnlyStrategy());
```

### CostOptimizedStrategy

Sorts providers by cost (lowest first).

```dart
aiKit.setStrategy(CostOptimizedStrategy());
```

### CustomPriorityStrategy

Custom provider priority order.

```dart
aiKit.setStrategy(CustomPriorityStrategy([
  'my_local_model',
  'zhipu_glm',
  'openai_gpt',
]));
```

## Execution Context

Control execution behavior with `AIExecutionContext`:

```dart
final result = await aiKit.execute(
  task,
  context: AIExecutionContext(
    hasNetwork: true,
    allowCloudFallback: true,
    allowLocalFallback: true,
    timeout: Duration(seconds: 10),
  ),
);
```

### Presets

```dart
// Local only
AIExecutionContext.localOnly(timeout: Duration(seconds: 5))

// Cloud only
AIExecutionContext.cloudOnly(
  hasNetwork: true,
  timeout: Duration(seconds: 10),
)

// Default (allows all fallbacks)
AIExecutionContext.defaults(
  hasNetwork: true,
  timeout: Duration(seconds: 30),
)
```

## Provider Packages

Flutter AI Kit uses a modular architecture. Core package contains only interfaces.

Provider implementations are in separate packages:

- `flutter_ai_kit_tflite` - TensorFlow Lite local models
- `flutter_ai_kit_zhipu` - Zhipu GLM cloud API
- `flutter_ai_kit_qwen` - Qwen cloud API
- `flutter_ai_kit_openai` - OpenAI cloud API

## License

MIT

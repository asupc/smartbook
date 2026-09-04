# flutter_ai_kit_openai

OpenAI compatible protocol implementation for flutter_ai_kit.

## Features

- ✅ Support OpenAI official API
- ✅ Support ZhipuGLM (OpenAI format)
- ✅ Support custom OpenAI-compatible services (SiliconFlow, DeepSeek, etc.)
- ✅ Text chat, vision recognition, and audio transcription capabilities
- ✅ Hybrid model configuration: simple default + optional advanced settings
- ✅ Complete type definitions and error handling

## Getting Started

### Installation

```yaml
dependencies:
  flutter_ai_kit: ^1.0.0
  flutter_ai_kit_openai: ^1.0.0
```

### Basic Usage

```dart
import 'package:flutter_ai_kit_openai/flutter_ai_kit_openai.dart';

// Simple configuration
final config = ServicePresets.zhipuGLM(apiKey: 'your-key');
final provider = OpenAIChatProvider(config: config);

// Execute task
final task = MyTextTask('Hello');
final result = await provider.execute(task);
```

### Advanced Configuration

```dart
// Separate models for different capabilities
final config = ServicePresets.zhipuGLM(
  apiKey: 'your-key',
  textModel: 'glm-4-flash',      // Text tasks
  visionModel: 'glm-4v-flash',   // Vision tasks
  audioModel: 'glm-4-voice',     // Audio tasks
);
```

## License

MIT

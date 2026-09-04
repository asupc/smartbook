/// Flutter AI Kit - A universal AI capability kit for Flutter
///
/// Supports local models (TFLite, ONNX) and cloud APIs (OpenAI, Zhipu, etc.)
library flutter_ai_kit;

// Core
export 'src/core/ai_task.dart';
export 'src/core/ai_provider.dart';
export 'src/core/ai_result.dart';
export 'src/core/ai_execution_context.dart';

// Strategies
export 'src/strategies/ai_execution_strategy.dart';
export 'src/strategies/local_first_strategy.dart';
export 'src/strategies/cloud_first_strategy.dart';
export 'src/strategies/local_only_strategy.dart';
export 'src/strategies/cloud_only_strategy.dart';
export 'src/strategies/cost_optimized_strategy.dart';
export 'src/strategies/custom_priority_strategy.dart';

// Main class
export 'src/flutter_ai_kit.dart';

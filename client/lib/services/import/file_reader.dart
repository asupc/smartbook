import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:gbk_codec/gbk_codec.dart';

/// 文件读取进度回调
typedef ProgressCallback = void Function(double progress);

/// 文件读取服务
class FileReaderService {
  /// 读取文件内容为文本
  ///
  /// 支持:
  /// - CSV 文件 (自动检测编码: UTF-8, GBK, UTF-16)
  /// - XLSX 文件 (需要提供 xlsxConverter)
  ///
  /// [file] 要读取的文件
  /// [onProgress] 进度回调 (0.0 - 1.0)
  /// [xlsxConverter] XLSX 转 CSV 的转换器函数
  static Future<String> readFile(
    PlatformFile file, {
    ProgressCallback? onProgress,
    String Function(Uint8List)? xlsxConverter,
  }) async {
    // 检查文件扩展名
    final fileName = file.name.toLowerCase();
    final isXlsx = fileName.endsWith('.xlsx');

    // 读取文件字节
    List<int> bytes;
    if (file.path == null || file.path!.isEmpty) {
      bytes = file.bytes ?? [];
      if (bytes.isEmpty) return '';
    } else {
      bytes = await _readFileWithProgress(
        file.path!,
        onProgress: onProgress,
      );
    }

    if (bytes.isEmpty) return '';

    // 转换为文本
    if (isXlsx) {
      if (xlsxConverter == null) {
        throw ArgumentError('xlsxConverter is required for XLSX files');
      }
      return xlsxConverter(Uint8List.fromList(bytes));
    } else {
      return decodeBytes(bytes);
    }
  }

  /// 流式读取文件并显示进度
  static Future<List<int>> _readFileWithProgress(
    String filePath, {
    ProgressCallback? onProgress,
  }) async {
    final file = File(filePath);
    final exists = await file.exists();
    if (!exists) return [];

    const int chunkSize = 256 * 1024; // 256KB
    final length = await file.length();
    final raf = await file.open();

    try {
      final chunks = <List<int>>[];
      int offset = 0;

      while (offset < length) {
        final toRead =
            (length - offset) < chunkSize ? (length - offset) : chunkSize;
        final bytes = await raf.read(toRead);
        if (bytes.isEmpty) break;

        chunks.add(bytes);
        offset += bytes.length;

        if (onProgress != null) {
          onProgress(offset / (length == 0 ? 1 : length));
        }

        await Future<void>.delayed(Duration.zero);
      }

      final all = <int>[];
      for (final c in chunks) {
        all.addAll(c);
      }
      return all;
    } finally {
      await raf.close();
    }
  }

  /// 解码字节为文本，自动识别编码
  ///
  /// 支持的编码:
  /// - UTF-16 (LE/BE with BOM)
  /// - UTF-8 (with/without BOM)
  /// - GBK (中文)
  /// - Latin1 (兜底)
  static String decodeBytes(List<int> bytes) {
    if (bytes.length >= 2) {
      // UTF-16 LE BOM FF FE
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        try {
          final codeUnits = <int>[];
          for (int i = 2; i + 1 < bytes.length; i += 2) {
            codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
          }
          return String.fromCharCodes(codeUnits);
        } catch (_) {}
      }
      // UTF-16 BE BOM FE FF
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        try {
          final codeUnits = <int>[];
          for (int i = 2; i + 1 < bytes.length; i += 2) {
            codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
          }
          return String.fromCharCodes(codeUnits);
        } catch (_) {}
      }
    }

    // UTF-8 BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }

    // 尝试 UTF-8 解码
    try {
      final utfText = utf8.decode(bytes, allowMalformed: false);
      // 检测是否有乱码字符 (Unicode replacement character U+FFFD)
      if (!utfText.contains('\uFFFD')) {
        return utfText;
      }
    } catch (_) {
      // UTF-8 解码失败，继续尝试 GBK
    }

    // 尝试 GBK 解码（支付宝旧版本 Windows 导出常用）
    try {
      final gbkText = gbk_bytes.decode(bytes);
      // 简单检测：如果包含常见中文字符，认为GBK解码成功
      if (_containsChineseCharacters(gbkText)) {
        return gbkText;
      }
    } catch (_) {
      // GBK 解码失败
    }

    // 兜底：使用 allowMalformed 的 UTF-8
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      // 最后的兜底 latin1
      return latin1.decode(bytes);
    }
  }

  /// 检测文本中是否包含中文字符
  static bool _containsChineseCharacters(String text) {
    // 检查常见汉字范围 (基本汉字: U+4E00-U+9FFF)
    final chineseRegex = RegExp(r'[\u4E00-\u9FFF]');
    return chineseRegex.hasMatch(text);
  }
}

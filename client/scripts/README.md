# 项目工具脚本

本目录包含 SmartBook 项目的各种开发工具脚本。

## 📁 目录结构

```
scripts/
├── i18n/              # 国际化翻译管理工具
│   ├── check_unused_i18n.dart
│   ├── clean_unused_i18n.dart
│   └── verify_translations.dart
└── README.md          # 本文件
```

## 🛠️ 工具分类

### 📝 i18n 管理工具

- **check_unused_i18n.dart** - 检测未使用的翻译 keys
- **clean_unused_i18n.dart** - 清理未使用的翻译 keys
- **verify_translations.dart** - 验证中英文翻译完整性

## 🚀 快速开始

### i18n 工具使用

```bash
# 验证中英文翻译完整性
dart scripts/i18n/verify_translations.dart

# 检测未使用的 keys
dart scripts/i18n/check_unused_i18n.dart

# 清理未使用的 keys
dart scripts/i18n/clean_unused_i18n.dart
```

## 📦 未来计划

- 🔧 构建工具
- 🧪 测试工具
- 📊 分析工具
- 🎨 资源管理工具

## 💡 添加新工具

如果要添加新的工具分类，建议的结构：

```
scripts/
├── category_name/
│   ├── tool1.dart
│   ├── tool2.dart
│   └── README.md
└── README.md
```

每个工具目录应包含：
1. 工具脚本文件（.dart）
2. README.md 说明文档
3. 必要的配置文件

## 📖 相关文档

- 贡献指南: `docs/contributing/CONTRIBUTING_ZH.md`
- 开发规范: `CLAUDE.md`

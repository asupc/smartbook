# ☁️ 云同步配置指南

> 🌐 [English](cloud-setup_EN.md)

SmartBook 支持 5 种云同步方案,根据你的使用场景选择最合适的一种。

## 方案对比

| 方案 | 适用场景 | 特点 |
|---|---|---|
| **SmartBook 智记** | 多端实时协同 + 自托管 | Docker 一键、多设备秒同步、自带 Web 端、多用户 |
| **iCloud** | iOS 单平台用户 | 零配置、原生集成、Apple 生态 |
| **Supabase** | 无 NAS 的跨平台用户 | 免费额度充足、配置简单、云端托管 |
| **WebDAV** | NAS 用户 | 数据本地化、群晖/绿联云/Nextcloud |
| **S3 协议** | 灵活云存储 | Cloudflare R2/AWS S3/MinIO,免费额度大 |

---

## 🆕 SmartBook 智记(自建云同步 + Web 端)

> **多端实时秒级同步 + Web 管理端 + 多用户独立**,推荐有 NAS / VPS / Docker 环境的用户。

### 一键部署

```yaml
# docker-compose.yml
services:
  smartbook-cloud:
    image: smartbook-server:latest
    restart: unless-stopped
    ports:
      - "8869:8080"
    volumes:
      - ./data:/data
```

```bash
docker compose up -d
docker compose logs smartbook-cloud | grep -A 10 "初次启动"
```

输出类似:

```
 SmartBook 智记 — 初次启动,已自动创建管理员账号:

   邮箱:    owner@example.com
   密码:    FIDodUnwprkw1zUi
```

拿这个账号:

- 浏览器访问 `http://<服务器 IP>:8869` 即可用 **Web 管理端**
- App 里选「SmartBook 智记」,填服务器地址 + 上面账号登录

### 添加家人 / 队友

Web 后台 →「用户」→「新增用户」输入对方邮箱和密码 → 告诉他们登录就行。每个用户数据互相隔离,看不到别人的账本。

### 进阶配置

```yaml
services:
  smartbook-cloud:
    image: smartbook-server:latest
    restart: unless-stopped
    ports:
      - "8869:8080"
    environment:
      # 自指定管理员账号(替代默认随机生成):
      BOOTSTRAP_ADMIN_EMAIL: me@example.com
      BOOTSTRAP_ADMIN_PASSWORD: <你的强密码>
      # 自指定 JWT 密钥(默认会自动生成到 /data/.jwt_secret):
      # JWT_SECRET: <32+ 字节随机串>
    volumes:
      - ./data:/data
```

### 提示

- **PWA 支持**:Web 管理端已接入 PWA,浏览器地址栏右侧会出现"安装"图标,点一下就能把 Web 作为独立 app 装到桌面 / Dock / 开始菜单
- **数据位置**:SQLite 数据库 + 附件 + JWT 密钥全部在 `./data/` 目录,迁移/备份整个目录就行
- **公网部署**:建议在前面套一层 nginx / caddy 做 HTTPS + 域名

[📖 SmartBook-Cloud 仓库 + 备份系统 + 代码审查报告 →](https://github.com/TNT-Likely/BeeCount-Cloud)

---

## 方案二:iCloud(推荐 iOS 用户)

**适用场景**:iOS 用户,追求零配置、无缝同步体验。

**优势**:

- ✅ 零配置:无需任何设置,开箱即用
- ✅ 原生集成:使用 Apple ID 自动同步
- ✅ 隐私保护:数据存储在你的 iCloud Drive 中
- ✅ 多设备同步:iPhone、iPad 数据自动同步

**使用方式**:

1. 确保 iOS 设备已登录 iCloud 并开启 iCloud Drive
2. 打开智记 → 个人中心 → 云服务
3. 选择 **iCloud**,即可开始同步

> 💡 iCloud 同步仅支持 iOS 设备。需要 iOS + Android 跨平台请用 Supabase / S3 / SmartBook 智记。

---

## 方案三:Supabase(推荐新手)

**适用场景**:没有 NAS 设备,想要快速开始的用户。

**配置步骤**:

1. **创建 Supabase 项目**
   - 访问 [supabase.com](https://supabase.com) 注册账号
   - 创建新项目,选择合适的区域
   - 在项目设置中获取 URL 和 anon key

2. **配置 Storage**
   - 在 Supabase 控制台创建名为 `beecount-backups` 的 Storage Bucket
   - 设置为 Private(不勾选 Public bucket)
   - **配置 RLS 访问策略**:需要创建 4 条策略,确保用户只能访问自己的数据
     - 进入 bucket 的 Policies 标签页
     - 分别创建以下 4 条策略(每条策略配置相同):
       - **SELECT**:允许用户读取自己的备份文件
       - **INSERT**:允许用户创建新的备份文件
       - **UPDATE**:允许用户更新自己的备份文件
       - **DELETE**:允许用户删除自己的备份文件
     - 每条策略的配置:
       - **Policy name**: 可自定义(如 `Allow user access to own backups`)
       - **Target roles**: 选择 `authenticated`
       - **Policy definition**: 输入以下表达式

         ```sql
         ((bucket_id = 'beecount-backups'::text) AND ((storage.foldername(name))[1] = 'users'::text) AND ((storage.foldername(name))[2] = (auth.uid())::text))
         ```

       - 此策略确保用户只能访问 `beecount-backups/users/<自己的用户ID>/` 路径下的文件

3. **应用内配置**
   - 打开智记 → 个人中心 → 云服务
   - 点击"添加自定义云服务"
   - 选择服务类型:**Supabase**
   - 填入你的 Supabase URL 和 anon key
   - 保存并启用配置
   - 点击"登录",注册/登录账号后即可开始同步

---

## 方案四:WebDAV(推荐 NAS 用户)

**适用场景**:已有 NAS 设备或私有云存储的用户。

**支持的服务**:

- ✅ 绿联云 NAS
- ✅ 群晖 Synology NAS
- ✅ Nextcloud
- ✅ 坚果云 WebDAV
- ✅ ownCloud
- ✅ 其他支持 WebDAV 协议的服务器

**配置步骤**:

1. **启用 WebDAV 服务**
   - 在 NAS 或云存储平台启用 WebDAV 功能
   - 记录 WebDAV 服务器地址(如 `http://nas.local:5005`)
   - 创建或使用现有的用户账号

2. **准备存储目录**(可选)
   - 在 WebDAV 根目录下创建 `SmartBook` 文件夹
   - 或使用任意路径(配置时指定即可)

3. **应用内配置**
   - 打开智记 → 个人中心 → 云服务
   - 点击"添加自定义云服务"
   - 选择服务类型:**WebDAV**
   - 填写配置信息:
     - **WebDAV 服务器 URL**:如 `http://nas.local:5005`
     - **用户名**:你的 WebDAV 用户名
     - **密码**:你的 WebDAV 密码
     - **远程路径**:存储路径(如 `/home/SmartBook` 或 `/SmartBook`)
   - 点击"测试连接"验证配置
   - 保存并启用配置
   - WebDAV 无需额外登录,配置后即可直接同步

**常见 WebDAV 配置示例**:

```
绿联云 NAS:
- URL: http://你的NAS地址:5005
- 远程路径: /home/SmartBook

群晖 NAS:
- URL: http://你的NAS地址:5005 或 https://你的域名
- 远程路径: /SmartBook

坚果云:
- URL: https://dav.jianguoyun.com/dav/
- 远程路径: /SmartBook
```

---

## 方案五:S3 协议存储(推荐追求灵活性)

**适用场景**:需要灵活选择云服务商,或想利用免费额度的用户。

**支持的服务**:

- ✅ **Cloudflare R2**(推荐,10GB 免费存储)
- ✅ **AWS S3**
- ✅ **MinIO**(开源自建)
- ✅ **阿里云 OSS** / **腾讯云 COS**(S3 兼容模式)
- ✅ 其他 S3 协议兼容服务

**配置步骤(以 Cloudflare R2 为例)**:

1. **创建 R2 存储桶**
   - 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
   - 进入 **R2** 服务
   - 创建新存储桶(Bucket),如命名为 `beecount-backups`
   - 记录存储桶名称

2. **获取 API 凭证**
   - 在 R2 页面点击 **Manage R2 API Tokens**
   - 创建新的 API Token
   - 权限选择 **Object Read & Write**
   - 记录以下信息:
     - **Access Key ID**(访问密钥)
     - **Secret Access Key**(私密密钥)
     - **Endpoint**(如 `<账户ID>.r2.cloudflarestorage.com`)

3. **应用内配置**
   - 打开智记 → 个人中心 → 云服务
   - 点击"添加自定义云服务"
   - 选择服务类型:**S3 协议存储**
   - 填写配置信息:
     - **端点地址**:Cloudflare R2 endpoint(不含 `https://`)
     - **区域**:`auto`(R2 自动选择区域)
     - **Access Key**:你的 Access Key ID
     - **Secret Key**:你的 Secret Access Key
     - **存储桶名称**:创建的存储桶名称(如 `beecount-backups`)
     - **使用 HTTPS**:开启(推荐)
     - **端口**:留空(使用默认端口)
   - 点击"测试连接"验证配置
   - 保存并启用配置

**其他 S3 服务配置示例**:

```
Cloudflare R2:
- 端点地址: <账户ID>.r2.cloudflarestorage.com
- 区域: auto
- 使用 HTTPS: 是

AWS S3:
- 端点地址: s3.amazonaws.com
- 区域: us-east-1(根据存储桶区域填写)
- 使用 HTTPS: 是

MinIO(自建):
- 端点地址: minio.example.com
- 区域: us-east-1 或 auto
- 使用 HTTPS: 根据配置选择
- 端口: 9000(或自定义端口)

阿里云 OSS(S3 兼容模式):
- 端点地址: oss-cn-hangzhou.aliyuncs.com
- 区域: oss-cn-hangzhou
- 使用 HTTPS: 是
```

> 💡 **提示**:
>
> - 端点地址请**不要**包含 `http://` 或 `https://` 前缀
> - Cloudflare R2 免费额度:10GB 存储 + 每月 1000 万次 A 类操作

---

## 常见问题

**Q: 应该选哪个方案?**

- iOS 单设备 → **iCloud**
- 多端实时协同 + 自托管 → **SmartBook 智记**
- 跨平台无 NAS → **Supabase** 或 **S3**
- 有 NAS → **WebDAV**

**Q: WebDAV 配置后无法上传?**

- 检查 WebDAV 服务是否启用且端口正确
- 确认用户名和密码正确
- 某些 NAS 的 WebDAV 需要在特定路径下才能写入(如绿联云需要 `/home/` 路径)
- 点击"测试连接"按钮查看详细错误信息

**Q: S3 配置后连接失败?**

- 确认端点地址**不包含** `http://` 或 `https://` 前缀
- 检查 Access Key 和 Secret Key 是否正确
- 确认存储桶名称拼写正确
- 检查存储桶区域是否匹配(AWS S3 需要准确区域,Cloudflare R2 使用 `auto`)

**Q: 如何在多设备间同步?**

- iCloud:iOS 设备登录同一 Apple ID,数据自动同步
- SmartBook 智记:所有设备配置相同服务器地址 + 同账号登录
- Supabase:所有设备配置相同的 URL 和 anon key,登录同一账号
- WebDAV:所有设备配置相同的 WebDAV 服务器地址和凭据
- S3:所有设备配置相同的 S3 端点、Access Key 和存储桶名称

---

## 后续规划

- 📦 Google Drive
- 📦 Dropbox
- 📦 OneDrive

如果你希望优先支持某个云服务,欢迎在 [Issues](https://github.com/TNT-Likely/BeeCount/issues) 中提出需求!

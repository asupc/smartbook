# ☁️ Cloud Sync Configuration Guide

> 🌐 [中文](cloud-setup.md)

SmartBook supports 5 cloud sync options. Choose based on your scenario.

## Comparison

| Option | Best For | Highlights |
|---|---|---|
| **SmartBook** | Real-time multi-device + self-hosted | One-click Docker, sub-second sync, built-in Web, multi-user |
| **iCloud** | iOS-only users | Zero config, native integration, Apple ecosystem |
| **Supabase** | Cross-platform without NAS | Generous free tier, easy setup, hosted |
| **WebDAV** | NAS users | Local data, Synology/Nextcloud/etc. |
| **S3 protocol** | Flexible cloud storage | Cloudflare R2/AWS S3/MinIO, large free tier |

---

## 🆕 SmartBook (Self-hosted Sync + Web)

> **Sub-second multi-device sync + Web admin + multi-user isolation.** Recommended for users with NAS / VPS / Docker.

### One-click Deploy

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
docker compose logs smartbook-cloud | grep -A 10 "first launch"
```

Output similar to:

```
 SmartBook — first launch, admin account auto-created:

   Email:    owner@example.com
   Password: FIDodUnwprkw1zUi
```

With this account:

- Open `http://<server-ip>:8869` in browser → **Web admin console**
- In the App, choose "SmartBook", enter server URL + credentials

### Add Family / Teammates

Web console → "Users" → "Add User" with their email and password → tell them to log in. Each user's data is isolated.

### Advanced Configuration

```yaml
services:
  smartbook-cloud:
    image: smartbook-server:latest
    restart: unless-stopped
    ports:
      - "8869:8080"
    environment:
      # Override default random admin:
      BOOTSTRAP_ADMIN_EMAIL: me@example.com
      BOOTSTRAP_ADMIN_PASSWORD: <strong password>
      # Override JWT secret (default: auto-generated to /data/.jwt_secret):
      # JWT_SECRET: <32+ byte random string>
    volumes:
      - ./data:/data
```

### Tips

- **PWA support**: Web admin is a PWA — install icon appears in the address bar to install as a desktop app
- **Data location**: SQLite + attachments + JWT secret all live in `./data/`. Migrate / back up the whole directory.
- **Public deployment**: Front with nginx / caddy for HTTPS + domain.

[📖 SmartBook-Cloud repo + backup system + audit reports →](https://github.com/TNT-Likely/BeeCount-Cloud)

---

## Option 2: iCloud (Recommended for iOS)

**Best for**: iOS users wanting zero-config, seamless sync.

**Pros**:

- ✅ Zero config: works out of the box
- ✅ Native: auto-sync via Apple ID
- ✅ Privacy: data in your iCloud Drive
- ✅ Multi-device: iPhone + iPad auto-sync

**Setup**:

1. Sign in to iCloud and enable iCloud Drive on the device
2. Open SmartBook → Profile → Cloud Service
3. Choose **iCloud**

> 💡 iCloud only works between iOS devices. For iOS + Android, use Supabase / S3 / SmartBook.

---

## Option 3: Supabase (Beginner-friendly)

**Best for**: Users without NAS who want quick setup.

**Setup**:

1. **Create Supabase project**
   - Sign up at [supabase.com](https://supabase.com)
   - Create a new project; pick a region
   - Get URL and anon key from project settings

2. **Configure Storage**
   - Create a bucket named `beecount-backups`
   - Set it to Private (don't check Public bucket)
   - **Configure RLS policies**: Create 4 policies so users can only access their own data
     - Go to bucket Policies tab
     - Create the following 4 policies (same configuration each):
       - **SELECT**: read own backup files
       - **INSERT**: create new backups
       - **UPDATE**: update own backups
       - **DELETE**: delete own backups
     - Each policy:
       - **Policy name**: customizable (e.g. `Allow user access to own backups`)
       - **Target roles**: `authenticated`
       - **Policy definition**:

         ```sql
         ((bucket_id = 'beecount-backups'::text) AND ((storage.foldername(name))[1] = 'users'::text) AND ((storage.foldername(name))[2] = (auth.uid())::text))
         ```

       - This ensures users only access `beecount-backups/users/<their-user-id>/`.

3. **Configure in app**
   - Open SmartBook → Profile → Cloud Service
   - Tap "Add custom cloud service"
   - Service type: **Supabase**
   - Enter your URL and anon key
   - Save and enable
   - Tap "Sign in", register or log in to start syncing

---

## Option 4: WebDAV (Recommended for NAS Users)

**Best for**: Users with NAS or private cloud storage.

**Supported services**:

- ✅ UGREEN NAS
- ✅ Synology NAS
- ✅ Nextcloud
- ✅ Jianguoyun WebDAV
- ✅ ownCloud
- ✅ Other WebDAV-compatible servers

**Setup**:

1. **Enable WebDAV**
   - Enable WebDAV on your NAS or cloud platform
   - Note the server URL (e.g. `http://nas.local:5005`)
   - Create or use an existing user account

2. **Prepare directory** (optional)
   - Create `SmartBook` folder under WebDAV root, or use any path

3. **Configure in app**
   - Open SmartBook → Profile → Cloud Service
   - Tap "Add custom cloud service"
   - Service type: **WebDAV**
   - Fill in:
     - **WebDAV server URL**: e.g. `http://nas.local:5005`
     - **Username** / **Password**
     - **Remote path**: e.g. `/home/SmartBook` or `/SmartBook`
   - Tap "Test connection" to verify
   - Save and enable. WebDAV doesn't need login — sync starts after configuration.

**Common WebDAV examples**:

```
UGREEN NAS:
- URL: http://your-nas:5005
- Remote path: /home/SmartBook

Synology NAS:
- URL: http://your-nas:5005 or https://your-domain
- Remote path: /SmartBook

Jianguoyun:
- URL: https://dav.jianguoyun.com/dav/
- Remote path: /SmartBook
```

---

## Option 5: S3 Protocol (Recommended for Flexibility)

**Best for**: Users who want flexible cloud providers or generous free tiers.

**Supported services**:

- ✅ **Cloudflare R2** (recommended, 10GB free)
- ✅ **AWS S3**
- ✅ **MinIO** (self-hosted)
- ✅ **Aliyun OSS** / **Tencent COS** (S3-compatible)
- ✅ Others S3-protocol compatible storages

**Setup (using Cloudflare R2)**:

1. **Create R2 bucket**
   - Log into [Cloudflare Dashboard](https://dash.cloudflare.com/)
   - Open **R2**
   - Create a bucket like `beecount-backups`
   - Note the bucket name

2. **Get API credentials**
   - Click **Manage R2 API Tokens**
   - Create a new API Token
   - Permission: **Object Read & Write**
   - Note:
     - **Access Key ID**
     - **Secret Access Key**
     - **Endpoint** (like `<account-id>.r2.cloudflarestorage.com`)

3. **Configure in app**
   - Open SmartBook → Profile → Cloud Service
   - Tap "Add custom cloud service"
   - Service type: **S3 Protocol**
   - Fill in:
     - **Endpoint**: R2 endpoint (no `https://`)
     - **Region**: `auto`
     - **Access Key** / **Secret Key**
     - **Bucket name**: e.g. `beecount-backups`
     - **Use HTTPS**: enable (recommended)
     - **Port**: leave blank
   - Tap "Test connection" to verify
   - Save and enable

**Other S3 examples**:

```
Cloudflare R2:
- Endpoint: <account-id>.r2.cloudflarestorage.com
- Region: auto
- Use HTTPS: yes

AWS S3:
- Endpoint: s3.amazonaws.com
- Region: us-east-1 (use your bucket's region)
- Use HTTPS: yes

MinIO (self-hosted):
- Endpoint: minio.example.com
- Region: us-east-1 or auto
- Use HTTPS: based on your config
- Port: 9000 (or your custom)

Aliyun OSS (S3-compatible):
- Endpoint: oss-cn-hangzhou.aliyuncs.com
- Region: oss-cn-hangzhou
- Use HTTPS: yes
```

> 💡 **Tips**:
>
> - **Don't** include `http://` or `https://` in the endpoint
> - Cloudflare R2 free tier: 10GB storage + 10M Class A operations / month

---

## FAQ

**Q: Which option should I pick?**

- iOS single device → **iCloud**
- Multi-device real-time + self-host → **SmartBook**
- Cross-platform without NAS → **Supabase** or **S3**
- Have a NAS → **WebDAV**

**Q: WebDAV upload failing?**

- Check WebDAV is enabled and port is correct
- Verify username and password
- Some NAS WebDAV needs specific paths (e.g. UGREEN needs `/home/`)
- Tap "Test connection" for detailed errors

**Q: S3 connection failing?**

- Endpoint must **not** include `http://` or `https://`
- Verify Access Key and Secret Key
- Verify bucket name spelling
- Check bucket region matches (AWS S3 needs exact, R2 uses `auto`)

**Q: How to sync between devices?**

- iCloud: log into the same Apple ID
- SmartBook: same server URL + same account
- Supabase: same URL and anon key, same account
- WebDAV: same server URL and credentials
- S3: same endpoint, Access Key, and bucket

---

## Roadmap

- 📦 Google Drive
- 📦 Dropbox
- 📦 OneDrive

If you want to prioritize a service, please raise an [Issue](https://github.com/TNT-Likely/BeeCount/issues)!

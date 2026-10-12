"""AI 出站 host 策略(SSRF 默认拒绝)。

背景:provider 的 `baseUrl` 完全由用户配置(`UserProfile.ai_config_json`),
服务端又替用户发起出站 HTTP(`/ai/relay/{chat,vision,stt}`、`/ai/providers/test`、
`/ai/test-provider`、`/ai/parse-tx-*`、`/ai/ask`)。没有任何约束时,一个普通
账号就能把服务端当**内网探测代理**:

- `http://127.0.0.1:6379/...`、`http://169.254.169.254/latest/meta-data/...`
  (云元数据)、Docker 内网服务名 —— 请求真实发出,并且带着该用户存在服务端的
  apiKey(`Authorization: Bearer ...`),响应前 200 字还会经 `error_message`
  回读;
- `/providers/test` 更直接:请求体不带 key 时服务端**从存储取出真 key 代发**。

因此这里实现**默认拒绝**策略:

- 目标 host 是环回 / 链路本地 / 私网 / 保留段(IPv4 + IPv6 + 十进制等
  非规范写法,覆盖 `169.254.169.254`、`::1`、`::ffff:127.0.0.1`、`2130706433`)
  → 拒绝;
- 目标 host 是域名时,做一次**尽力而为**的 DNS 解析并检查解析结果(防
  `localhost` / 攻击者可控域名指向 127.0.0.1)。解析失败不算违规(交给 httpx
  报网络错误),避免把 DNS 抖动变成配置错误;
- 自建 Ollama / 局域网 vLLM 等确实要打私网的用户,把 host 显式写进
  `AI_ALLOWED_PRIVATE_HOSTS`(逗号分隔,默认空)即放行 —— 策略从「默认放行」
  变成「显式 opt-in」,不牺牲自托管可用性;
- 不校验 scheme:非 http(s) 由 httpx 抛 `UnsupportedProtocol` 后归一成 502,
  与既有行为/用例一致(见 `test_relay_non_http_scheme_base_url_no_500`)。

调用点(必须全覆盖,否则等于没修):

- `services/ai/provider_client.py` 的所有 egress 入口(chat/vision/stt/stream
  的 openai 与 anthropic 分支)在发请求前 `enforce_outbound_url`;
- 共享连接池 `get_ai_http_client()` 与 `routers/ai/test_provider.py` 的 4 处
  自建 `AsyncClient` 都挂 `OUTBOUND_REQUEST_HOOKS`:每个实际请求(含重定向
  续跳)都过一遍策略 —— 这层是兜底,覆盖未来新增的直接出站代码。

已知局限(记在文档里,避免误判为"已完全覆盖"):

1. DNS rebinding TOCTOU:策略里的解析与 httpx 实际连接是两次独立解析。窗口
   极短且需要攻击者同时控制 DNS 与配好 baseUrl(自部署场景里通常就是同一个人),
   风险可接受;要彻底消除需「连接固定 IP + 手写 Host 头」,改动面过大。
2. 重定向:AI 出站 `follow_redirects` 保持默认 False(不跟随),所以
   「跨 host 重定向外带 apiKey」不可达;hook 仍然逐跳校验以兜住未来改动。
"""
from __future__ import annotations

import ipaddress
import logging
import re
import socket
import time
from urllib.parse import urlsplit

from ...config import get_settings

logger = logging.getLogger(__name__)

__all__ = [
    "AiHostNotAllowedError",
    "ChatProviderError",
    "enforce_outbound_url",
    "is_host_allowed",
    "is_ip_allowed",
    "allowed_private_hosts",
    "outbound_event_hooks",
]

# 兜底排除段:`ipaddress.is_global` 之外的边角(6to4 中继任播、6to4/Teredo
# 隧道、site-local、NAT64 前缀、IPv4 保留段)。命中即视为不可出站。
_EXTRA_BLOCKED_NETS = tuple(
    ipaddress.ip_network(n)
    for n in (
        "0.0.0.0/8",          # "this network"
        "192.0.0.0/24",       # IETF protocol assignments
        "192.88.99.0/24",     # 6to4 relay anycast
        "198.18.0.0/15",      # benchmarking
        "240.0.0.0/4",        # reserved (+ 255.255.255.255)
        "64:ff9b::/96",       # NAT64 well-known prefix
        "2002::/16",          # 6to4
        "fec0::/10",          # deprecated site-local
    )
)

# 特殊域名:解析前直接拒(不依赖 DNS,`localhost` 在部分解析器上会兜底成
# 环回,先拦更稳)。
_BLOCKED_HOSTNAMES = frozenset(
    {"localhost", "localhost.localdomain", "ip6-localhost", "ip6-loopback"}
)

_HOST_MAX_LEN = 64
_RESOLVE_CACHE_TTL_S = 60.0
_resolve_cache: dict[str, tuple[float, tuple[str, ...]]] = {}


class ChatProviderError(RuntimeError):
    """通用 provider 调用失败（含配置类 host 策略拒绝）。

    定义在本模块（而不是 `provider_client`）是为了让 `AiHostNotAllowedError`
    能安全地继承它 —— `provider_client` 反向 import 本模块，若基类定义在
    `provider_client` 会形成循环依赖。

    `provider_client` 的 `ChatProviderError` 从这里 re-export（同一对象，
    `isinstance` 与既有 `from ...provider_client import ChatProviderError`
    调用方全部继续成立）。
    """


class AiHostNotAllowedError(ChatProviderError):
    """出站目标 host 命中 SSRF 策略（拒绝或未显式放行）。

    **必须是 `ChatProviderError` 的子类**（2026-10-11 对抗缺陷 2，BLOCKER）：
    历史实现只继承 `RuntimeError`，于是所有「只捕获 `ChatProviderError`」的
    调用点（`/ai/parse-tx-image`、`/ai/parse-tx-text`、`/ai/ask` 的 SSE 分支）
    漏掉它 → SSRF 拒绝变成未捕获异常 → 500 INTERNAL_ERROR。客户端拿到 500
    会当 transient 无限重试，而这是**配置类错误**，重试永远不会成功。

    语义分工（由调用方按类型再分派，relay.py 就是先 `except
    AiHostNotAllowedError` 再 `except ChatProviderError`）：

    - 本类 → 400（配置类，`AI_PROVIDER_HOST_NOT_ALLOWED` / 探测入口
      `AI_TEST_HOST_NOT_ALLOWED` / 解析入口沿用各自 4xx 归一）；
    - 其它 `ChatProviderError` → 502（上游 transient，客户端可重试）。

    继承关系保证**万一**某个调用点只捕获基类，最坏退化成 502 而不是 500。
    """


def allowed_private_hosts() -> frozenset[str]:
    """`AI_ALLOWED_PRIVATE_HOSTS` 的解析结果(小写、去空)。"""
    raw = getattr(get_settings(), "ai_relay_allow_private_hosts", "") or ""
    if not raw:
        raw = getattr(get_settings(), "ai_allowed_private_hosts", "") or ""
    return frozenset(x.strip().lower() for x in raw.split(",") if x.strip())


def _in_extra_blocked(ip: ipaddress._BaseAddress) -> bool:
    try:
        return any(ip in net for net in _EXTRA_BLOCKED_NETS if net.version == ip.version)
    except TypeError:  # pragma: no cover — 版本已对齐,防御性
        return False


def _is_public_address(ip: ipaddress._BaseAddress) -> bool:
    """公网地址判据。

    `is_global` 是主判据(它已排除 RFC1918 / 环回 / 链路本地 / 组播 /
    保留段 / `100.64.0.0/10` CGNAT / `::1` / `fc00::/7` / `fe80::/10` /
    `2001:db8::/32` 等);再叠加 `_EXTRA_BLOCKED_NETS` 兜住少数
    `is_global=True` 的边角(6to4 中继任播、NAT64、site-local)。
    IPv4-mapped / 6to4 隧道地址递归看内层 IPv4。
    """
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return _is_public_address(ip.ipv4_mapped)
        if ip.sixtofour is not None:
            return _is_public_address(ip.sixtofour)
    if not ip.is_global:
        return False
    return not _in_extra_blocked(ip)


def _parse_ip_literal(host: str) -> ipaddress._BaseAddress | None:
    """把 host 解析成 IP,支持非规范写法(inet_aton 语义)。

    除标准 `a.b.c.d` / IPv6 外,还识别 `2130706433`(十进制整数)、
    `0x7f000001`、`017700000001`(八进制)与 `127.1` / `10.1`(缺段补零,
    末段吃掉剩余字节)。这些写法在部分解析器(尤其 Linux glibc)下会连到
    真实私网地址,而 `ipaddress.ip_address` 只认标准写法 —— 必须自己展开,
    否则策略形同虚设。
    """
    h = host.strip().strip("[]")
    if not h or len(h) > _HOST_MAX_LEN:
        return None
    try:
        return ipaddress.ip_address(h)
    except ValueError:
        pass

    parts = h.split(".")
    if not 1 <= len(parts) <= 4:
        return None
    nums: list[int] = []
    try:
        for p in parts:
            if re.fullmatch(r"0[xX][0-9a-fA-F]{1,8}", p):
                nums.append(int(p, 16))
            elif re.fullmatch(r"0[0-7]{1,22}", p):
                nums.append(int(p, 8))
            elif p.isdigit():
                nums.append(int(p))
            else:
                return None
        if len(nums) == 4:
            value = (nums[0] << 24) | (nums[1] << 16) | (nums[2] << 8) | nums[3]
        elif len(nums) == 3:
            value = (nums[0] << 24) | (nums[1] << 16) | nums[2]
        elif len(nums) == 2:
            value = (nums[0] << 24) | nums[1]
        else:
            value = nums[0]
        if not 0 <= value <= 0xFFFFFFFF:
            return None
        return ipaddress.ip_address(value)
    except (ValueError, OverflowError):
        return None


def _resolve_host(host: str) -> tuple[str, ...]:
    """尽力而为解析,带 60s 缓存;失败返回空元组(= 不判定为违规)。"""
    now = time.monotonic()
    cached = _resolve_cache.get(host)
    if cached is not None and now - cached[0] < _RESOLVE_CACHE_TTL_S:
        return cached[1]
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except (OSError, UnicodeError):
        return ()
    addrs = tuple({info[4][0] for info in infos if info[4]})
    # 缓存有界:只保留最近的 256 个条目,防无界增长(host 由用户控制)。
    if len(_resolve_cache) >= 256:
        _resolve_cache.clear()
    _resolve_cache[host] = (now, addrs)
    return addrs


def is_ip_allowed(host: str | None) -> bool:
    """host 是 IP 字面量(含非规范写法)时判是否允许出站。域名返回 True。

    域名不在这里判 —— 见 `is_host_allowed` 的解析分支。
    """
    if not host:
        return False
    if host.strip().lower() in allowed_private_hosts():
        return True
    ip = _parse_ip_literal(host)
    if ip is None:
        return True
    return _is_public_address(ip)


def is_host_allowed(host: str | None) -> bool:
    """出站 host 是否允许(裸 host,不含 scheme)。

    规则(顺序):
      1. 空 host → 拒(无法定位目标,调用方本来也会因 baseUrl 空而报配置错);
      2. `AI_ALLOWED_PRIVATE_HOSTS` 显式列出的 host → 放行(自托管 opt-in);
      3. `localhost` 等特殊名 → 拒;
      4. IP 字面量(含十进制/八进制/十六进制/缺段写法)→ 按地址类别判;
      5. 域名 → 尽力解析,任一解析结果非公网即拒;解析失败 → 放行(交给
         httpx 报网络错误,不把 DNS 抖动当配置错误)。
    """
    if not host:
        return False
    normalized = host.strip().strip("[]").lower()
    if not normalized:
        return False
    if normalized in allowed_private_hosts():
        return True
    if normalized in _BLOCKED_HOSTNAMES:
        return False
    ip = _parse_ip_literal(normalized)
    if ip is not None:
        return _is_public_address(ip)
    for addr in _resolve_host(normalized):
        resolved = _parse_ip_literal(addr)
        if resolved is not None and not _is_public_address(resolved):
            logger.warning(
                "ai.outbound.blocked host=%s resolved=%s reason=private_resolution",
                normalized, addr,
            )
            return False
    return True


def _host_of(url: str) -> str | None:
    try:
        return urlsplit(url).hostname
    except (ValueError, UnicodeError):  # pragma: no cover — 畸形 URL
        return None


_SECURE_SCHEMES = frozenset({"http", "https"})


def enforce_outbound_url(url: str, *, context: str = "ai") -> None:
    """出站前校验;违规抛 `AiHostNotAllowedError`。

    非 http(s) scheme(`file://` / `gopher://` …)与「http(s) 但无 host」不在这里
    拦:httpx 自己会抛 `UnsupportedProtocol` / transport 错误,既有路径归一成
    502 AI_PROVIDER_ERROR,语义已经正确且不泄露栈 —— policy 只负责 host 维度,
    替换错误类型反而会把 502 变成 500。返回前不抛 = 放行(可能后续仍被 httpx 拒)。
    """
    try:
        scheme = urlsplit(url).scheme.lower()
    except (ValueError, UnicodeError):  # pragma: no cover
        return
    if scheme not in _SECURE_SCHEMES:
        return
    host = _host_of(url)
    if not host:
        return
    if is_host_allowed(host):
        return
    logger.warning(
        "ai.outbound.blocked context=%s host=%s url_len=%d reason=host_policy",
        context, host, len(url or ""),
    )
    raise AiHostNotAllowedError(
        f"outbound host {host!r} is not allowed by the AI SSRF policy "
        f"(loopback / link-local / private / reserved targets are denied; add "
        f"the host to AI_ALLOWED_PRIVATE_HOSTS to allow a self-hosted LLM endpoint)"
    )


async def _enforce_request_hook(request) -> None:
    """httpx request event hook —— 每个实际出站请求(含重定向续跳)都过策略。"""
    enforce_outbound_url(str(request.url), context="httpx_hook")


def outbound_event_hooks() -> dict[str, list]:
    """新建 client 时用的 event_hooks(每次返回**独立** dict —— httpx 会持有并
    可能修改该映射,模块级共享会在多 client 间串扰)。"""
    return {"request": [_enforce_request_hook]}

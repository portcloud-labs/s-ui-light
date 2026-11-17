# s-ui-light

适用于小内存 Alpine Linux / Debian / Ubuntu 的 [s-ui](https://github.com/alireza0/s-ui) 面板部署方案。

GitHub Action 每日自动同步 s-ui 最新版本，单一安装脚本自动检测系统与架构，一键部署。

## 快速安装

```bash
wget -O install.sh https://raw.githubusercontent.com/portcloud-labs/s-ui-light/main/scripts/install.sh && chmod +x install.sh && ./install.sh
```

脚本会自动检测操作系统与架构：

- **Alpine Linux** → OpenRC 服务（`rc-service` / `rc-update`）
- **Debian / Ubuntu** → systemd 服务（`systemctl`）

开始下载前会询问一次是否限速：低于 96 MiB 默认限速 1M/s，96 MiB 及以上默认不限速。
提示会显示检测到的内存，无法检测时默认限速。下载过程带进度条。

首次启动服务前可以设置面板端口和订阅端口，提示会显示默认值：

```text
Panel port [2095]:
Subscription port [2096]:
```

直接回车使用默认值；重复安装时显示并保留已有端口。两个端口必须不同，且位于 1–65535。
无人值守时使用已有端口或新安装默认值，也可通过参数或环境变量显式指定。

## 安装后会做什么

安装完服务后，脚本会依次询问并完成五件事：

1. **重置管理员密码**（无需询问）。用户名保持 `admin`，密码改为随机生成的 24 位强密码，
   并在最后打印出来。s-ui 只存密码哈希，**这串密码只会显示这一次，请立刻保存**。

2. **是否给面板启用 HTTPS**（**强烈建议开启**，Y/n，回车默认 yes）。选 yes 会生成自签证书供面板 2095 使用，
   浏览器需要信任此证书；选 no 则面板使用 HTTP。**订阅 2096 始终使用 HTTP**，避免 Clash
   因无法验证自签证书而下载失败。再次运行脚本时，也会清除旧的订阅证书设置并修正订阅入口协议。

3. **是否部署 Hysteria2 节点**（Y/n，回车默认 yes）。选 yes 会创建一个 Hysteria2 入站：

   - 复用上面生成的自签证书（第 2 步选了 no 就现在生成）
   - 可输入 UDP 端口；回车默认使用本次随机生成的端口（20000–59999），提示会显示具体默认值
   - SNI 从几个热门站点中随机选一个
   - 已开启「允许不安全」（`client.insecure`），客户端无需校验证书
   - 新建入站默认启用 Salamander 混淆，每个入站独立生成 24 位安全随机字母数字密码；
     随机生成失败时跳过创建，不会降级为无混淆入站

   混淆密码与**管理员密码、客户端认证密码不同**，不会在安装日志或摘要中打印。
   在面板中新增客户端并勾选该入站后，面板原生 URI/Mihomo 订阅会自动携带 Salamander
   参数与混淆密码，无需脚本另行拼接。请将订阅作为敏感信息保管，并使用支持 Salamander 的客户端。
   此默认设置**只作用于脚本新建的 Hysteria2 入站**，不会自动修改已有节点或其他协议。
   Salamander 仅提供混淆，不是抗封锁或防探测保证；本次不配置 masquerade。

4. **是否部署 VLESS + Reality 节点**（y/N）。选 yes 会创建一个 VLESS 入站：

   > **警告：sing-box 对 VLESS 的实现有 BUG，更容易被 GFW 封锁。如确需使用 VLESS 协议，建议使用基于 Xray 的 [3x-ui](https://github.com/MHSanaei/3x-ui)。**
   > 脚本会在创建询问前用加粗红色警告显示此提醒；`--yes` 模式也会显示。

   - Reality 模式，不需要任何证书：服务端借用 SNI 所指站点的握手。密钥对通过
     面板的 `api/keypairs` 接口生成（X25519）
   - 可输入 TCP 端口，回车默认 **443/TCP**；请确保该端口未被其他服务占用
   - 选择端口时会提示：非 443 端口可能增加服务器 IP 被 GFW 封禁的风险。
     该提示参照 [Xray REALITY 的端口警告](https://github.com/XTLS/Xray-core/blob/main/infra/conf/xray.go)
   - SNI 从几个热门站点中随机选一个（与第 3 步独立抽取），handshake 目标同 SNI，443 端口
   - short_id 随机生成（单个随机字节）
   - 客户端侧已开启 uTLS，指纹为 `chrome`

   VLESS 原生 URI 订阅会自动携带 `security=reality&pbk=…&sid=…&fp=chrome`。

5. **是否创建无限流量客户端并应用 Clash 模板**（Y/n，回车默认 yes）。选 yes 会：

   - 创建随机名称、独立于管理员密码的客户端，流量不限、永久有效，勾选当前全部入站；
     后续新增入站需在面板另行分配
   - 使用公网 IPv4 命名，无 IPv4 时使用公网 IPv6；通过 ipwho.is 查询国家地区，
     节点名类似 `🇦🇺澳大利亚节点 · Hy2`、`🇦🇺澳大利亚节点 · VLESS`；使用 IPv6 发布地址时，
     名称为 `🇦🇺澳大利亚节点 v6 · Hy2`。无法查询时使用 `🚀加速节点` 前缀
   - 排除私网、CGNAT、回环、链路本地、文档网段及其他保留地址；国家查询失败静默回退
   - 为尚未设置发布地址的入站填写检测到的公网 IP；已有发布地址和映射端口保持原样。
     入站名称同步缩短，去掉内部标签和端口编号；已有订阅也会看到新名称。
     单次运行每种协议只创建一个入站，IPv4/IPv6 不会各创建一个；重复运行或手动新增导致
     同协议多个入站时，才会用 `Hy2 2` 等最短编号区分
   - 应用内置的 iCloud、Apple、Microsoft、Steam、科研、AI、境外网站、广告、国内和兜底分流模板；
     面板自动生成真实节点和认证信息。`🚀 节点选择` 集中列出全部节点及一个 `DIRECT`，
     其他策略组原来列出节点的位置改为引用 `🚀 节点选择`，保留各组原有的默认选择顺序
   - **安装结束直接打印 Clash YAML 订阅地址**：
     `http://公网IP:2096/sub/随机客户端名称?format=clash`；IPv6 自动加方括号

   Clash 模板为面板全局设置，会影响现有客户端的 Clash 订阅。替换前将旧模板及相关开关以
   仅当前用户可读权限备份到 `$INSTALL_DIR/clash-template-backup-<客户端名称>.json`。
   脚本使用 `jq` 安全处理面板 JSON，缺少时自动安装。拒绝此步骤时仍可在面板手动创建客户端。

> 部署完成后请自行放行对应端口：Hysteria2 走 **UDP**，VLESS + Reality 走 **TCP**。
> 脚本会在摘要里打印端口号。

### 证书说明

自签证书为 ECDSA P-256、有效期 10 年，存放在 `/usr/local/s-ui/cert/`，私钥权限 600。

Alpine 的 OpenSSL 是 LibreSSL，用 `-newkey ec` 生成的证书会把曲线写成显式参数，
Go 无法解析（s-ui 会报 `x509: invalid ECDSA parameters`）。脚本因此改用
`ecparam -param_enc named_curve`，该写法在 Alpine 的 LibreSSL 与 Debian/Ubuntu 的
OpenSSL 3 上都能被 s-ui 正常加载。

## 服务管理

### Alpine Linux

```bash
rc-service s-ui start               # 启动
rc-service s-ui stop                # 停止
rc-service s-ui restart             # 重启
rc-service s-ui status              # 状态
tail -f /var/log/s-ui.log           # 查看日志
```

### Debian / Ubuntu

```bash
systemctl start s-ui                # 启动
systemctl stop s-ui                 # 停止
systemctl restart s-ui              # 重启
systemctl status s-ui               # 状态
tail -f /var/log/s-ui.log           # 查看日志
```

服务已配置开机自启和崩溃自动重启。

## 选项

```bash
./install.sh --arch arm64           # 指定架构（默认自动检测）
./install.sh --version v1.4.2       # 指定版本（默认最新）
./install.sh --panel-port 3000     # 自定义面板端口（新安装默认 2095）
./install.sh --sub-port 3001       # 自定义订阅端口（新安装默认 2096）
./install.sh --hy2-port 23456      # Hy2 UDP 端口（默认随机）
./install.sh --vless-port 443      # VLESS TCP 端口（默认 443）
./install.sh --download-rate 256K   # 下载限速（低于 96 MiB 默认 1M，否则不限速；跳过询问）
./install.sh --low-mem on           # 强制低内存模式（默认 auto 自动检测）
./install.sh --uninstall            # 卸载
./install.sh --no-prompt            # 跳过所有交互（无人值守；下载按内存选择默认限速）
./install.sh --yes                  # 全部交互问题都答 yes
```

`--no-prompt` 适合脚本化部署：跳过 HTTPS、Hysteria2 与 VLESS，只装服务并重置密码。
端口也可通过 `SUI_PANEL_PORT`、`SUI_SUB_PORT` 环境变量设置，命令行参数优先。例如：
`./install.sh --no-prompt --panel-port 3000 --sub-port 3001`。
没有终端时（如 `curl | sh`、cron）会跳过所有交互问题，不会卡住等待输入；下载按检测到的内存选择默认值：低于 96 MiB 限速 1M/s，96 MiB 及以上不限速；
无法检测内存时保留 1M/s 限速。

密码重置始终执行 —— 装完却保留 `admin/admin` 默认密码，是最容易被扫到的风险。

## 小内存 / 64 MB 容器与限速下载

`s-ui` 的二进制约 100 MiB，而目标机器可能只有 **64 MiB 的 cgroup 硬限制**。安装脚本针对这种情况做了几件事：

- **下载限速可选，按内存选择默认值**：低于 96 MiB 默认 `y`（1M/s，106 MiB 约 1.8 分钟），
  96 MiB 及以上默认 `n`（不限速）。提示显示检测到的内存，仅在低于 96 MiB 时建议限速，
  以减轻 page cache 压力和 OOM 风险。优先使用 cgroup 内存上限；无上限时读取
  `/proc/meminfo` 的物理内存，无法检测时默认保持限速。按回车接受默认值，也可答 `y` / `n` 切换。
  `--download-rate`（如 `256K`、`2M`、`0`）或环境变量 `SUI_DOWNLOAD_RATE` 优先并跳过询问。
  `--yes` / `--no-prompt` / 无终端（`curl | sh`、cron）时不询问，使用相同的内存默认规则。
- **下载进度条**：stderr 是终端时用 `curl --progress-bar` 显示单行进度条
  （百分比、速度、剩余时间）；输出被重定向到文件或管道时自动静默，避免进度字符污染日志。
- Alpine 自带的 busybox `wget` 没有 `--limit-rate`，所以下载统一改用脚本本来就依赖的 `curl`；
  同时不再检查/安装 `wget`，少一次 `apk add`（包管理本身也很吃内存）。
- **流式写盘 + 断点续传**：响应体直接写入 `sui.part`，绝不读进 shell 变量；
  `curl -C -` 支持中断后续传，最多重试 5 次。限速能避免 page cache 瞬时涨满，
  减少内核回收抖动和误伤 `sshd` 等进程。
- **完整性校验**：下载完成后校验 ELF 魔数、最小体积，并尽力从 GitHub Release API 取
  `size` / `sha256` digest 比对（也可用 `SUI_SHA256` 手工指定）。校验不过就丢弃重下，
  **不会把残缺二进制 chmod 后启动** —— 否则会变成崩溃重启循环，反复冲击内存。
- **自动 Go 运行时护栏**：脚本读 `/sys/fs/cgroup/memory.max`（cgroup v2）或
  `memory.limit_in_bytes`（v1）判断真实上限；**不看 `free`**，因为容器里 `free` 报的是
  宿主机内存（实测 5.9 GiB vs 真实 64 MiB）。当上限 ≤ 256 MiB 时自动注入：

  | 变量 | 值 | 作用 |
  |---|---|---|
  | `GOMEMLIMIT` | 上限的 5/8（64 MiB → `40MiB`） | Go 软内存上限，提前触发 GC |
  | `GOGC` | `30` | 更激进的 GC 目标 |
  | `GOMAXPROCS` | `1` | 限制 GC/辅助线程，适配 1 核容器 |
  | `GODEBUG` | `madvdontneed=1` | 释放内存时立即归还内核 |

  这些变量同时写进 **OpenRC / systemd 单元** 和脚本直接调起的 `sui admin` / `sui setting`
  短命进程（后者不走 service，最容易漏）。`--low-mem off` 可完全关闭；`auto`（默认）只在
  检测到小 cgroup 时启用，**大内存机器不受影响**。
- **升级时先停服务再换二进制**，避免新旧两份 100+ MiB mmap 镜像同时占内存。
- 不再下载可选的 `s-ui-<arch>.sh` 管理脚本（服务不需要它）。

推荐在极小内存容器上的用法：

```bash
./install.sh --no-prompt --download-rate 256K
```

`--no-prompt` 不建任何入站，内存占用最低。已在 64 MiB / 1 CPU 的 Alpine 容器上验证：
安装与运行期间 `oom_kill` 计数未增加，面板 HTTPS 与登录正常。注意 64 MiB 依然非常紧，
反复新开 SSH 会话可能挤掉 sshd 的 pre-auth 进程；如需多开节点，建议把容器限额提到 128–256 MiB。

> 端口转发：容器内监听 配置的面板/订阅 TCP 端口（默认 2095/2096） 与 Hysteria2 的 UDP 端口，是否在公网可达取决于
> 宿主机的 NAT/端口映射，脚本无法代劳。

## Salamander 验证范围

已在 Debian 12 / arm64 隔离容器中运行 s-ui v1.6.6（sing-box v1.14.4），调用安装器的实际入站创建函数，验证每个入站的混淆密码独立、原生 URI/Mihomo 订阅携带正确参数，并用 Mihomo v1.19.32 完成 HTTPS 访问和 UDP DNS 查询。错误或缺失混淆密码无法代理；随机密码生成不足 24 位时不创建入站；面板与核心重启后密钥保留且仍可连接。

此项验证不覆盖完整安装流程、跨 GFW 可用性或抗封锁效果。

## 安装完成后的访问地址

部署摘要使用实际配置的面板、订阅端口生成链接，会尝试获取公网 IPv4、IPv6，并收集网卡地址，公网地址优先显示。
同一个地址只显示一次（IPv6 不同写法也会去重），IPv6 链接自动加方括号。
公网探测使用 ipify，每个请求最多等待 4 秒；网络不可用、超时或返回无效内容时
静默跳过，不影响安装。NAT 服务器仍需由服务商配置端口映射，链接中的端口为面板监听端口。

### 2096 Clash YAML 订阅

可选客户端创建成功后，从安装完成摘要复制包含 `?format=clash` 的完整链接，直接导入
Mihomo / Clash.Meta 客户端。默认订阅端口为 **2096/TCP**，使用 HTTP，不受面板 HTTPS 选择影响。
摘要尊重已有订阅端口、路径和域名，`subURI` 的路径、域名和端口保留，协议改为 HTTP。

随机客户端名是订阅访问标识，任何持有完整链接的人都能下载配置，应妥善保管。
NAT 服务器需要映射订阅端口及节点协议端口；自动探测只能确定公网出口 IP，不能推断
服务商的公网映射端口。若出口 IP 不是服务商分配的入站地址，应在面板修改入站发布地址，
并通过订阅设置的 `subURI` 填写实际公网订阅入口。探测失败时不会填入保留地址作为公网 IP。

国家查询只在创建客户端时执行，不会在每次订阅下载时访问外部服务；每次请求最多 4 秒。
GeoIP 为数据库判断结果，可能与机房实际位置不同；IPv4 查询失败时保留 IPv4 的选择并使用通用名称，
不会仅为获取另一国家名称而改用 IPv6。

验证：在 Alpine 容器中运行 S-UI v1.6.6，通过脚本实际创建 Hysteria2、VLESS + Reality 和无限客户端，
从 2096 下载 YAML，验证全部入站分配、11 个策略组、Salamander/Reality 参数和完成摘要中的双栈链接。
此验证使用固定测试地址和国家结果，不代表真实 NAT 端口映射或跨网络连通性测试。
完整订阅同时通过 Mihomo v1.19.32 的 `-t -f` 配置检查。摘要中的自动订阅链接仅使用通过公网地址检查的 IP。
回归检查：`sh tests/subscription-smoke.sh`（需要 `jq`、`openssl`）。
协议与名称检查：`sh tests/transport-smoke.sh`、`sh tests/node-names-smoke.sh`。
端口检查：`sh tests/ports-smoke.sh`。
已在真实 S-UI v1.6.6 中验证面板 HTTPS + 订阅 HTTP、切回全部 HTTP，以及 2096 返回的短名称、策略组引用及认证参数。

### 节点端口

选择创建节点后才会询问对应端口，例如：

```text
Hy2 port (random default) [28782]:
[WRN] Non-443 VLESS ports may increase the risk of your server IP being blocked by the GFW.
VLESS port [443]:
```

Hy2 回车使用显示的随机默认值；VLESS 回车使用 443。也可通过 `SUI_HY2_PORT`、
`SUI_VLESS_PORT` 或 `--hy2-port`、`--vless-port` 直接指定，并跳过对应端口询问。
显式指定端口不会自动开启对应协议，仍遵循创建节点的询问或 `--yes` / `--no-prompt`。

端口范围为 1–65535。VLESS 的 TCP 端口不能与面板、订阅端口相同；Hy2 使用 UDP，
可以与 TCP 服务共用相同的端口数字。摘要和订阅中的节点端口会使用实际选择值。

### IPv4 / IPv6 双栈节点

同时检测到公网 IPv4 和本机可绑定的公网 IPv6 时，脚本会为 Hy2/VLESS 分别发布两个地址族的入站，
复用端口与 TLS/混淆设置：IPv4 绑定 `0.0.0.0`，IPv6 绑定本机公网 IPv6。
已有客户端会同步分配到对应 IPv6 入站；重复执行不会重复创建同一 IPv6 入站。
只有 IPv6 的服务器直接使用原有 IPv6 入站，不额外复制。

国家查询仍优先 IPv4；无法识别时，名称为 `🚀加速节点 · Hy2`、`🚀加速节点 v6 · Hy2`，
VLESS 同样使用 `v6 · VLESS`。IPv4 和 IPv6 分别计数，不会把首个 IPv6 节点命名为第二个同协议节点。
外部 IPv6 探测失败时，仅回退到网卡上通过公网地址校验的 IPv6，忽略 ULA、链路本地与保留地址。

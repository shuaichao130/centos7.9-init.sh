# Sub2API Automatic Alipay Ledger Bridge

Sub2API 的独立 EasyPay 支付桥接服务。当前版本采用“浮动金额锁 + 支付宝官方账务明细 OpenAPI”的自动对账模式：用户不需要填写转账后 4 位、备注或订单号，服务根据支付宝商家账单自动识别到账并回调 Sub2API。

当前部署位置：`/opt/sub2api/sub2api-pay-bridge`  
公网入口：`https://pay.goaiflow.cloud`  
本地监听：`0.0.0.0:8000`  
systemd：`sub2api-pay-bridge.service`

主项目 `/opt/sub2api` 的 Go 二进制、配置和业务源码未被修改；支付桥接是独立 Python 服务。Nginx 和 systemd 属于部署层配置。

## 1. 项目目标

服务在 Sub2API 与个人支付宝收款码之间提供兼容层：

- 接收 Sub2API 的 EasyPay 统一下单请求。
- 为每笔订单分配短时唯一的实际应付金额，例如 `10.00`、`10.01`、`10.02`。
- 收银台只展示支付宝收款码、实际应付金额和倒计时。
- 后台每 5 秒查询支付宝官方商家账务明细。
- 通过金额、时间、收入方向和流水唯一性完成自动对账。
- 对账成功后，用 EasyPay MD5 签名回调 Sub2API，完成余额充值。

原始充值金额和实际付款金额是两个独立字段：

```text
Sub2API 原始充值金额: 10.00
本次实际应付金额:     10.01
```

回调 Sub2API 时使用原始充值金额 `10.00`；支付宝账单匹配时使用实际应付金额 `10.01`。

## 2. 总体架构

```text
                         HTTPS
                          |
                    pay.goaiflow.cloud
                          |
                         Nginx
                          |
                    127.0.0.1:8000
                          |
                 FastAPI / Uvicorn 服务
                          |
       +------------------+------------------+
       |                                     |
  EasyPay HTTP 接口                    SQLite WAL
       |                           auto_orders
       |                           auto_consumed_ledger
       |
  Sub2API 创建订单                    金额锁池
       |                         threading.Lock
       v
  cashier 收银台  <--- 用户支付宝扫码转账
                                      |
                                      v
                         支付宝官方 OpenAPI
                    alipay.data.bill.accountlog.query
                                      |
                                      v
                          对账与流水去重引擎
                                      |
                                      v
                         EasyPay MD5 Webhook
                                      |
                                      v
                              Sub2API 充值
```

### 2.1 订单时序

```text
1. Sub2API -> POST /mapi.php
2. 桥接服务校验 PID、MD5 签名和金额
3. 金额锁池分配唯一 actual_money
4. SQLite 写入订单，锁定 180 秒
5. 返回 payurl=/cashier?trade_no=...
6. 用户在电脑收银台查看金额并扫码付款
7. 后台线程每 5 秒读取支付宝账务明细
8. 匹配成功：订单 paid，释放金额槽位
9. 异步 POST EasyPay 成功通知到 Sub2API
10. Sub2API 完成充值，收银台轮询显示成功
```

## 3. 目录结构与职责

```text
/opt/sub2api/sub2api-pay-bridge/
├── main.py                         # 完整 FastAPI 服务与自动对账引擎
├── .env                            # 生产配置，包含密钥，权限 600
├── .env.example                    # 脱敏配置模板
├── requirements.txt                # Python 依赖锁定范围
├── README.md                       # 本文档
├── .gitignore                      # 忽略密钥、虚拟环境、数据库日志
├── .venv/                          # Python 虚拟环境，不提交到 Git
├── data/
│   └── orders.sqlite3              # SQLite 数据库与 WAL 文件
├── key/
│   ├── app_private_key.pem         # 原始应用私钥，裸 Base64 输入文件
│   ├── app_private_key_rsa.pem     # SDK 使用的 RSA PKCS#1 私钥
│   ├── alipay_public_key.pem       # 原始应用公钥文件
│   ├── alipay_public_key_wrapped.pem # 应用公钥 PEM 包装副本
│   └── alipay_platform_public_key.pem # 支付宝平台公钥，用于响应验签
├── pay/
│   ├── alipay.jpg                  # 当前自动流程使用的通用支付宝码
│   └── wxpay.jpg                   # 保留的微信通用码（当前自动流程备用）
├── tests/
│   └── test_bridge.py              # 金额锁、订单、账单匹配、签名测试
├── scripts/
│   └── smoke.sh                    # EasyPay 签名下单 smoke 测试
└── deploy/
    ├── sub2api-pay-bridge.service  # systemd 模板
    └── sub2api-pay-bridge.nginx.conf # Nginx 模板
```

### 3.1 密钥文件说明

支付宝配置中有两类公钥，不能混用：

- **应用公钥**：与应用私钥成对，用于在支付宝开放平台上传和生成应用配置。
- **支付宝公钥**：支付宝平台返回的公钥，用于验证支付宝 API 响应签名。

当前服务使用：

```env
ALIPAY_APP_PRIVATE_KEY_PATH=key/app_private_key_rsa.pem
ALIPAY_PUBLIC_KEY_PATH=key/alipay_platform_public_key.pem
```

所有密钥文件由 `sub2api` 用户读取，权限为 `600`。不要将密钥内容写入 README、日志、Nginx 配置或前端页面。

## 4. 技术栈

| 层次 | 技术 | 用途 |
| --- | --- | --- |
| 运行时 | Python 3.9 | 服务运行环境 |
| Web 框架 | FastAPI | HTTP API、收银台和健康检查 |
| ASGI 服务 | Uvicorn | 监听 `8000` 端口 |
| HTTP 客户端 | Requests | Sub2API 回调、Telegram 通知 |
| 支付 SDK | `alipay-sdk-python==3.7.1360` | 支付宝 OpenAPI 请求和 RSA2 响应验签 |
| 本地数据库 | SQLite | 订单、账单流水去重和回调状态持久化 |
| 并发控制 | `threading.Lock` | 金额锁池全局互斥 |
| 后台任务 | `threading.Thread` | 5 秒账单轮询 |
| 回调执行 | `ThreadPoolExecutor` | 异步发送 Sub2API Webhook |
| 反向代理 | Nginx | HTTPS、域名和本地端口代理 |
| 进程守护 | systemd | 开机启动、失败重启和日志管理 |

官方账务接口为 `GET /v3/alipay/data/bill/accountlog/query`，支付宝官方 SDK 的 Python 包负责请求签名和响应验签。[支付宝官方账务接口文档](https://github.com/alipay/alipay-sdk-php-all/blob/master/v3/docs/Api/AlipayDataBillAccountlogApi.md) · [支付宝官方 Python SDK](https://github.com/alipay/alipay-sdk-python-all)

## 5. 金额锁池

### 5.1 分配规则

当 Sub2API 请求基准金额 `M` 时：

```text
M.00 -> M.01 -> M.02 -> ...
```

默认配置：

```env
AMOUNT_LOCK_TTL_SECONDS=180
AMOUNT_LOCK_STEP_CENTS=1
AMOUNT_LOCK_MAX_SLOTS=1000
```

分配操作在同一个进程内由全局 `threading.Lock` 保护。SQLite 同时保存锁定结果，服务重启后会从 `auto_orders` 恢复有效锁。

### 5.2 释放规则

- 订单自动对账成功：立即释放。
- 主动关闭：立即释放。
- 订单超过 180 秒：金额槽位立即从锁池释放。
- 订单在过期后额外保留 30 秒用于账单匹配；宽限期结束后状态变为 `expired`。

因此，金额锁生命周期是 3 分钟，账单安全匹配窗口为：

```text
created_at - 10 秒 <= trans_time <= expires_at + 30 秒
```

## 6. 数据模型与状态机

### 6.1 `auto_orders`

核心字段：

| 字段 | 含义 |
| --- | --- |
| `trade_no` | 桥接服务本地交易号 |
| `out_trade_no` | Sub2API 商户订单号 |
| `money` | 原始充值金额 |
| `actual_money` | 用户实际应付金额 |
| `notify_url` | Sub2API EasyPay 回调地址 |
| `return_url` | 支付完成后的结果地址 |
| `status` | `pending`、`paid`、`expired`、`closed` |
| `alipay_order_no` | 已匹配的支付宝流水号 |
| `ledger_trans_time` | 支付宝流水交易时间 |
| `callback_done` | Sub2API 回调是否成功 |
| `callback_attempts` | 回调尝试次数 |
| `callback_error` | 最近一次回调错误 |

### 6.2 状态流转

```text
pending
  ├── 支付宝账单匹配成功 -> paid -> EasyPay 回调
  ├── 主动关闭         -> closed
  └── 180秒+30秒后      -> expired
```

`paid` 和 `callback_done` 分开保存：账单匹配成功后先确认本地支付事实，再异步重试 Sub2API 回调，避免网络短暂错误造成重复对账。

### 6.3 `auto_consumed_ledger`

以 `alipay_order_no` 为主键，记录已经消费的支付宝流水。数据库唯一约束和事务锁共同防止同一笔账单重复充值。

## 7. API 接口

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET/POST | `/mapi.php` | EasyPay 统一下单 |
| GET/POST | `/submit.php` | 兼容 EasyPay 页面下单入口 |
| GET | `/cashier?trade_no=...` | 金额、二维码、倒计时收银台 |
| GET | `/api/order/status?trade_no=...` | 前端支付状态轮询 |
| POST | `/api/order/close?trade_no=...` | 主动关闭并释放金额锁 |
| GET | `/api.php?act=order` | EasyPay 查单 |
| GET | `/payment-qr` | 返回支付宝收款码图片 |
| GET | `/health` | 查看服务和账单配置状态 |

### 7.1 下单响应示例

```json
{
  "code": 1,
  "msg": "success",
  "trade_no": "EP20260910123456ABCDEF1234",
  "out_trade_no": "sub2_example_001",
  "type": "alipay",
  "name": "余额充值",
  "money": "10.00",
  "actual_money": "10.01",
  "payurl": "https://pay.goaiflow.cloud/cashier?trade_no=EP...",
  "status": 0,
  "trade_status": "WAITPAY"
}
```

用户必须支付 `actual_money`，而不是只支付 `money`。收银台会突出显示实际金额并提示金额必须精确到分。

## 8. 自动对账引擎

后台线程的单次循环：

1. 将超过 `expires_at + 30s` 的待支付订单标记为 `expired`。
2. 释放已过期金额槽位并重建有效锁池。
3. 计算所有可匹配订单的最早查询时间。
4. 调用支付宝官方账户账务明细接口。
5. 丢弃支出流水、无流水号记录和无效金额记录。
6. 对每条收入流水执行四重校验：
   - `alipay_order_no` 未在 `auto_consumed_ledger` 中出现。
   - `trans_amount == actual_money`，精确到分。
   - `created_at - 10s <= trans_time`。
   - `trans_time <= expires_at + 30s`。
7. 只有恰好匹配一个订单时才结算；多订单同金额或时间不明确时保持待处理。
8. 使用 SQLite `BEGIN IMMEDIATE` 事务写入支付状态和消费流水。
9. 释放金额槽位，异步发送 EasyPay 回调。

支付宝密钥或 API 权限异常时，服务 fail-closed：不会把订单标记为已支付，也不会发送充值回调。

## 9. 配置说明

生产配置位于 `.env`，不要提交到代码仓库。主要配置如下：

```env
BIND_HOST=0.0.0.0
PORT=8000
PUBLIC_BASE_URL=https://pay.goaiflow.cloud

MERCHANT_PID=1001
MERCHANT_KEY=...

ALIPAY_QR_IMAGE_URL=pay/alipay.jpg
ALIPAY_APP_ID=2021003105674005
ALIPAY_APP_PRIVATE_KEY_PATH=key/app_private_key_rsa.pem
ALIPAY_PUBLIC_KEY_PATH=key/alipay_platform_public_key.pem
ALIPAY_GATEWAY=https://openapi.alipay.com/gateway.do
ALIPAY_LEDGER_ENABLED=true
ALIPAY_LEDGER_POLL_INTERVAL_SECONDS=5
ALIPAY_LEDGER_LOOKBACK_SECONDS=300
ALIPAY_LEDGER_TIMEZONE=Asia/Shanghai
ALIPAY_LEDGER_PAGE_SIZE=2000

AMOUNT_LOCK_TTL_SECONDS=180
AMOUNT_LOCK_STEP_CENTS=1
AMOUNT_LOCK_MAX_SLOTS=1000

SUB2API_WEBHOOK_URL=http://127.0.0.1:8080/api/v1/payment/webhook/easypay
DATABASE_PATH=data/orders.sqlite3
CALLBACK_TIMEOUT_SECONDS=15
CALLBACK_MAX_ATTEMPTS=3
UPSTREAM_TLS_VERIFY=true
```

当前自动对账版本只使用 `pay/alipay.jpg` 作为收款码图片；固定金额二维码已清理。实际应付金额由金额锁池动态分配，例如原始金额 `10.00` 可能显示为 `10.01`，因此固定金额二维码不适用于当前对账逻辑。`pay/wxpay.jpg` 保留作后续微信自动对账接入的素材，但当前账单引擎仅查询支付宝。

Telegram 只用于成功回调后的运营通知，不参与用户凭证输入：

```env
TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
```

## 10. 部署拓扑

```text
Internet
  |
  | HTTPS pay.goaiflow.cloud:443
  v
Nginx: /etc/nginx/conf.d/pay.goaiflow.cloud.conf
  |
  | proxy_pass http://127.0.0.1:8000
  v
sub2api-pay-bridge.service
  |
  +--> SQLite: data/orders.sqlite3
  +--> Alipay OpenAPI: openapi.alipay.com
  +--> Sub2API: 127.0.0.1:8080/api/v1/payment/webhook/easypay
```

systemd 实际配置：`/etc/systemd/system/sub2api-pay-bridge.service`。模板副本：`deploy/sub2api-pay-bridge.service`。

常用运维命令：

```bash
cd /opt/sub2api/sub2api-pay-bridge
systemctl status sub2api-pay-bridge.service
systemctl restart sub2api-pay-bridge.service
systemctl enable sub2api-pay-bridge.service
journalctl -u sub2api-pay-bridge.service -f
curl -fsS http://127.0.0.1:8000/health
```

Nginx 配置模板：`deploy/sub2api-pay-bridge.nginx.conf`。修改 Nginx 后检查：

```bash
nginx -t
systemctl reload nginx
```

## 11. 测试与验收

```bash
cd /opt/sub2api/sub2api-pay-bridge
python3 -m py_compile main.py tests/test_bridge.py
.venv/bin/python -m unittest discover -s tests -v
```

EasyPay 签名 smoke 测试：

```bash
cd /opt/sub2api/sub2api-pay-bridge
set -a; . ./.env; set +a
./scripts/smoke.sh
```

smoke 测试只创建待支付测试订单，不代表真实到账。测试订单可以通过以下接口关闭：

```bash
curl -X POST 'http://127.0.0.1:8000/api/order/close?trade_no=EP...'
```

验收重点：

- `/health` 中 `ledger_configured=true`。
- 同一基准金额的并发下单得到不同的 `actual_money`。
- 收银台展示浮动金额和 180 秒倒计时。
- 账单 API 返回成功时无验签错误日志。
- 模拟流水只结算一次。
- 回调使用原始 `money`，不是 `actual_money`。

## 12. 故障排查

### `ledger_configured=false`

检查 `.env` 中的两个路径和权限：

```bash
namei -l key/app_private_key_rsa.pem
namei -l key/alipay_platform_public_key.pem
stat -c '%a %U:%G %n' key/*.pem
```

systemd 以 `sub2api` 用户运行，密钥文件需要对该用户可读。

### 支付宝请求签名失败

确认 `app_private_key_rsa.pem` 是应用私钥，且格式为 RSA PKCS#1 PEM；应用私钥不能填写支付宝公钥。

### 支付宝响应验签失败

`ALIPAY_PUBLIC_KEY_PATH` 必须指向支付宝开放平台提供的支付宝公钥，不是与应用私钥成对的应用公钥。

### 账单返回成功但没有匹配订单

依次检查：

1. 用户支付的是否为页面展示的 `actual_money`。
2. 订单是否仍在 `expires_at + 30s` 内。
3. 交易是否确实进入当前支付宝商家账户。
4. 账单方向是否为收入。
5. 查看 `journalctl -u sub2api-pay-bridge.service`。

### 用户看到旧页面或二维码

使用新订单并刷新浏览器缓存。当前自动对账版本的 `payurl` 应指向：

```text
https://pay.goaiflow.cloud/cashier?trade_no=...
```

桥接收银台只负责展示金额和二维码；成功后显示成功状态，若由 Sub2API 弹窗打开则自动关闭，充值结果由 Sub2API 原页面处理。

## 13. 安全边界

- 不在日志中记录支付宝私钥、公钥内容、商户 KEY 或 Telegram Token。
- `/api.php` 的 `key` 查询请求在 Nginx 中关闭访问日志。
- 账单流水必须经过去重、金额、时间和收入方向检查。
- 任何支付宝 API 错误或响应验签错误都保持订单未支付。
- SQLite 只保存账单必要字段和脱敏后的原始流水 JSON，不保存用户支付凭据。
- 修改 `.env`、`key/`、`data/` 后保持属主 `sub2api:sub2api` 和最小权限。

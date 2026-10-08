# 设计 · 用 Chatwoot 原生承载 mobile-chat

- **日期**：2026-10-08
- **仓库**：`nothingp/chatwoot`（fork 自 `chatwoot/chatwoot`，基线 `07c668ec42`，零定制）
- **状态**：待评审

---

## 1. 背景与目标

现状是三层：`esimgo-web` → `ai-bridge`（自研 Node）→ Chatwoot + AnythingLLM。

`ai-bridge` 承担了移动端/Web 的会话入口：派生匿名身份、调业务 API 验证会员、把身份送进 Chatwoot 的 widget。这一层要**去掉**，改成 Chatwoot 原生承载。

**目标**

1. **`esimgo-web` 零代码改动** —— 只改两个配置项（`chatOrigin`、session 端点）指向 Chatwoot
2. 身份与业务凭据在**建会话时**写进 Chatwoot，后续调用直接取用
3. 其余全部复用 Chatwoot 原生机制（`ContactInboxWithContactBuilder`、`Widget::TokenService`、`WidgetsController`、`widgets/show`）

**非目标（本次不做）**

- Captain 的业务工具（订单 / 产品 / 购买）—— 本次只解决"身份和 token 怎么进 Chatwoot"
- 卡片消息的发送端
- 客户附件 OCR、消息合并（debounce）

---

## 2. 前端契约（不可变）

来源：`esimgo-web/src/features/customer-support/customer-support-types.ts`、`customer-support-session-service.ts`

### 请求

```
POST {sessionEndpoint}
Content-Type: application/json
token: <App 会员凭据>          ← 可选；匿名访客没有

{
  "platform": "web",
  "locale": "zh_CN",
  "systemLanguage": "zh-CN",
  "currency": "CNY",                 // 可选
  "catalogEnvironment": "prod",
  "entryPoint": "web_home_buy_esim",
  "appVersion": "web-0.1.0",
  "installationId": "<uuid v4>",
  "anonymousProfileId": "<uuid v4>",
  "resetChatIdentity": false,
  "identityContinuityKey": "cs1_<43>" // 可选
}
```

### 响应

```json
{
  "ok": true,
  "chatUrl": "https://<chatOrigin>/mobile-chat?session=<uuid v4>",
  "expiresAt": 1791425000000,
  "identityCookieScope": {
    "origin": "https://<chatOrigin>",
    "path": "/",
    "conversationCookieName": "cw_conversation",
    "userCookieName": "cw_user_<websiteToken>"
  },
  "identityContinuity": { "confirmed": false }
}
```

### 前端强校验（任何一条不符即拒）

```ts
chatUrl.origin              === config.chatOrigin
chatUrl.pathname.endsWith('/mobile-chat')
[...chatUrl.searchParams.keys()].length === 1
chatUrl.searchParams.getAll('session').length === 1
/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(session)
expiresAt > now + 1s  且  <= now + 20min
response.identityCookieScope.origin === config.chatOrigin
```

响应是 `.strict()` schema —— **多一个字段就整体拒收**。

**推论：`chatUrl` 必须是 `{chatOrigin}/mobile-chat?session=<uuid v4>`，且只能有这一个查询参数。**

---

## 3. 架构总览

```
esimgo-web（零改动，只改配置）
   │
   ├─ ① POST {chatwoot}/api/mobile-chat/session
   │
   └─ ② iframe src = {chatwoot}/mobile-chat?session=<uuid>
          │
          └─ ③ 302 → /widget?website_token=<..>&cw_conversation=<jwt>
                 （前端看不到这一步 —— 它只校验 ② 的 src）
                 │
                 └─ ④ Chatwoot 原生 widget，身份已经是那个人
```

**关键机制**：`/mobile-chat` 先把带身份的 `contact_inbox` 建好，再用 `cw_conversation` 把会话 token 传给 `/widget`。`WidgetsController#set_contact` 找到联系人就**不会重建**（`build_contact` 里 `return if @contact.present?`）。

**所以 `widgets/show.html.erb`、`WidgetsController`、widget app 全部零改动。**

---

## 4. 详细设计

### 4.1 路由（`config/routes.rb`）

```ruby
# 顶层，与 resource :widget 同级
get '/mobile-chat', to: 'mobile_chat#show'

# ★ 挂在 /public/api 下，不是 /api —— 见 4.8 CORS
namespace :public do
  namespace :api do
    namespace :v1 do
      namespace :mobile_chat do
        resource :session, only: [:create], controller: 'sessions'
      end
    end
  end
end
```

**为什么是 `/public/api/` 而不是 `/api/`**：见 4.8。

### 4.8 CORS（这是必需的，不是可选）

`esimgo-web` 是**跨域**调用 session 接口的。而 Chatwoot 的 `config/initializers/cors.rb` 只开放了：

```ruby
resource '/packs/*'      # 静态资源
resource '/audio/*'
resource '/public/api/*' # ← 明确留给外部 API
resource '/api/*'        # 仅当 ENABLE_API_CORS=true（给 dashboard API 用，太宽）
```

**所以挂到 `/public/api/*` 下 —— 不用改 `cors.rb`，也不用开 `ENABLE_API_CORS`。**

`/public/api/` 本来就是 Chatwoot 为「外部跨域 API」预留的命名空间（API Channel 的 `/public/api/v1/inboxes/:identifier/...` 就在这里）。

**另外要注意**：`/public/api/v1/inboxes/:identifier/...` 已经占用了这个命名空间 —— 新增的 `/public/api/v1/mobile_chat/session` 不冲突（不同前缀），但建议**确认 `BaseController` 的选择**：`Api::MobileChat::SessionsController` 应继承 `ActionController::Base`（或 `PublicController`），**不要**继承 `Api::V1::Accounts::BaseController`（那要求登录）。

> 对照 bridge：它有 `mobileChatCorsConfig` + origin 白名单。Chatwoot 侧靠 `/public/api/*` 的全开 CORS + 在 controller 里自己校验 `Origin`。**是否要加 origin 白名单**见 §10 待定项。

### 4.2 `Api::MobileChat::SessionsController#create`

**职责**：验身份 → 写 contact → 存 session → 返回契约响应。

```ruby
# 伪代码，非最终实现
def create
  inbox = configured_inbox                      # MOBILE_CHAT_INBOX_ID

  identity = MobileChat::IdentityResolver.new(
    token: request.headers['token'],
    installation_id: params[:installationId],
    anonymous_profile_id: params[:anonymousProfileId]
  ).perform                                     # → { identifier:, name:, email:, token: }

  contact_inbox = ContactInboxWithContactBuilder.new(
    inbox: inbox,
    contact_attributes: {
      identifier: identity.identifier,
      name: identity.name,
      email: identity.email,
      custom_attributes: identity.token.present? ? { 'app_token' => identity.token } : {}
    },
    source_id: identity.identifier,             # ★ 必须稳定 —— 见下方说明
    hmac_verified: true
  ).perform

  session_id = SecureRandom.uuid
  Redis::Alfred.setex(
    "mobile_chat:session:#{session_id}",
    { contact_inbox_id: contact_inbox.id, inbox_id: inbox.id }.to_json,
    20.minutes
  )

  render json: {
    ok: true,
    chatUrl: "#{ENV.fetch('FRONTEND_URL')}/mobile-chat?session=#{session_id}",
    expiresAt: (Time.current + 20.minutes).to_i * 1000,   # ★ 毫秒
    identityCookieScope: {
      origin: ENV.fetch('FRONTEND_URL'),
      path: '/',
      conversationCookieName: 'cw_conversation',
      userCookieName: "cw_user_#{inbox.channel.website_token}"
    },
    identityContinuity: { confirmed: false }
  }
end
```

**三个必须做对的点：**

1. **`source_id` 必须稳定**，不能是 `nil`。
   `ContactInboxWithContactBuilder` 的查找逻辑是 `inbox.contact_inboxes.find_by(source_id: source_id) if source_id.present?` —— **`source_id` 为空就每次新建一个 `contact_inbox`**，而 Chatwoot 的会话是绑 `contact_inbox` 的，等于**每次打开客服都是全新会话，历史断掉**。
   直接用 `identifier` 当 `source_id`（`(inbox_id, source_id)` 有唯一约束，且 identifier 本身就含会员/匿名区分）。

2. **`chatUrl` 的 base 是 `FRONTEND_URL`**，不是 `help_center_root`。
   前端校验 `chatUrl.origin === config.chatOrigin`，所以必须是**公网可达的 Chatwoot 地址** —— 也就是 `WidgetsController#web_widget_script` 用的同一个 `ENV['FRONTEND_URL']`。

3. **`expiresAt` 是毫秒时间戳**。
   前端 `Date.now()` 是毫秒，且校验 `expiresAt <= now + 1000` / `> now + 20min`。返回秒会直接被判过期。

**注意**：`contact.custom_attributes.app_token` 会**进入 Captain 的 system prompt**（`contact.liquid` 渲染 `custom_attributes`）。这是 2026-10-08 讨论中明确接受的取舍。

### 4.3 `MobileChatController#show`

**职责**：读 session → 建/找 contact_inbox → 签 widget token → 302。

```ruby
# 伪代码
def show
  raw = Redis::Alfred.get("mobile_chat:session:#{params[:session]}")
  return render_mobile_chat_expired if raw.blank?

  data = JSON.parse(raw)
  inbox = Inbox.find(data['inbox_id'])
  contact_inbox = ContactInbox.find(data['contact_inbox_id'])

  widget_token = Widget::TokenService.new(
    payload: { source_id: contact_inbox.source_id, inbox_id: inbox.id }
  ).generate_token

  redirect_to "/widget?website_token=#{inbox.channel.website_token}&cw_conversation=#{widget_token}"
end
```

**为什么是 302 不是渲染**：`/mobile-chat` 不渲染任何东西，只做跳转。这样 `widgets/show` 和 widget app 都不用动。

**session 一次性还是可重复**：可重复（`get` 不删）。同一 `chatUrl` 刷新页面仍可用，直到 TTL 到期。

### 4.4 session 存储

| 项 | 值 |
|---|---|
| Key | `mobile_chat:session:<uuid v4>` |
| Value | `{ "contact_inbox_id": 1, "inbox_id": 1 }` |
| TTL | 20 分钟（对齐前端 `MAX_SESSION_LIFETIME_MS` 与 `expiresAt` 校验） |
| 封装 | `Redis::Alfred.setex` / `.get`（`lib/redis/alfred.rb`） |

**key 前缀要加进 `lib/redis/redis_keys.rb` 的常量表**（该文件是 Chatwoot 的 key 登记处）。

### 4.5 身份派生

两个身份前缀，都满足前端的 `identifier` 格式约束：

```
会员：  member_<memberId>
匿名：  guest_<installationId>_<anonymousProfileId>
```

**判断会员**：请求带 `token` header → 调业务 API `GET {base}/v2/esim/user/info` with `token: <token>` header → 成功则取用户 ID；失败（401/404）**降级为匿名**，不报错。

> 决策记录（2026-10-08）：**不沿用 bridge 的 `HMAC(externalCustomerContextSecret)` 派生**。
> 理由：那个密钥的作用是隐私 + 固定长度，不是安全边界 —— 真正防冒充的是 Chatwoot 的 `hmac_token`（前端拿不到它，签不出 `identifier_hash`）。已确认不关心旧匿名用户的连续性，所以可以简化。
> **代价**：`installationId` / `memberId` 会明文出现在 `contact.identifier` 里（客服可见、API 可查）。
> **注意**：`identifier` 格式一旦上线就是长期契约（`contact.identifier` 会被持久化），后续改动等于重置联系人身份。

### 4.6 业务 API 客户端

用 Chatwoot 原生的 `SafeFetch`（`lib/safe_fetch.rb`，含超时/字节上限/重定向处理）。

```
GET {NOVYRO_API_BASE_URL}{NOVYRO_USER_INFO_PATH}     header: { token: <用户凭据> }
```

本次只需这一个调用（验身份）。订单查询在后续阶段。

### 4.7 配置（`InstallationConfig`）

沿用 Chatwoot 的标准做法 —— 和 `SLACK_CLIENT_SECRET` / `CAPTAIN_OPEN_AI_API_KEY` 同处，`type: secret` 让后台用密码框显示。

| 配置名 | 用途 | 默认 |
|---|---|---|
| `MOBILE_CHAT_INBOX_ID` | 决定 `website_token` + `hmac_token` 的 inbox | — |
| `NOVYRO_API_BASE_URL` | 业务 API 基址 | — |
| `NOVYRO_API_KEY` | 服务级凭据 `x-api-key` | — |
| `NOVYRO_SITE_ID` | `site-id` | — |
| `NOVYRO_USER_INFO_PATH` | 验身份路径 | `/v2/esim/user/info` |
| `NOVYRO_USER_ORDERS_PATH` | 订单路径（后续用） | `/v2/esim/user/orders` |

> `InstallationConfig` 是明文 jsonb 存储 —— 和其它内置凭据一致，不额外加密。

---

## 5. 数据流

### 建会话（会员）

```
esimgo-web ──token header──► SessionsController
                                │
                                ├─ SafeFetch → 业务 API /user/info      [token]
                                │     ← { id, name, email }
                                │
                                ├─ identifier = "member_<id>"
                                ├─ ContactInboxWithContactBuilder
                                │     contact.identifier = member_<id>
                                │     contact.custom_attributes.app_token = <token>
                                │     contact_inbox.hmac_verified = true
                                │
                                ├─ Redis: mobile_chat:session:<uuid>  (TTL 20min)
                                └─ 200 { chatUrl, expiresAt, ... }
```

### 建会话（匿名）

同上，但跳过业务 API 调用，`identifier = "guest_<installationId>_<anonymousProfileId>"`，不写 `app_token`。

### 打开聊天

```
esimgo-web ──iframe src──► /mobile-chat?session=<uuid>
                              │
                              ├─ Redis.get → contact_inbox_id
                              ├─ Widget::TokenService 签 cw_conversation
                              └─ 302 ──► /widget?website_token=..&cw_conversation=..
                                            │
                                            ├─ set_token 解出 source_id
                                            ├─ set_contact 找到 contact_inbox
                                            ├─ build_contact → @contact 已存在，不重建
                                            └─ 渲染原生聊天界面
```

---

## 6. 错误处理

| 场景 | 响应 | 前端表现 |
|---|---|---|
| `token` 无效 / 过期 | **降级为匿名**，正常返回 200 | 客户以匿名身份进入 |
| `installationId` / `anonymousProfileId` 不是 UUID v4 | `400` | 前端显示"客服不可用" |
| `MOBILE_CHAT_INBOX_ID` 未配 / inbox 不存在 | `500` + 记日志 | 同上 |
| 业务 API 超时 / 5xx | **降级为匿名**（不阻断建会话） | 客户以匿名身份进入 |
| `/mobile-chat` 的 session 过期或不存在 | 渲染 `410 Gone` 简单页 | iframe 内显示 |

**原则**：业务 API 的失败**不应该阻断建会话** —— 匿名也能聊（只是查不了订单）。只有"配置缺失"这类部署错误才 500。

---

## 7. 测试

| 层 | 覆盖 |
|---|---|
| **Request spec** — `spec/requests/public/api/v1/mobile_chat/sessions_spec.rb` | 契约完整性（§2 那几条强校验逐一对应）；会员/匿名两条路径；token 无效降级为匿名；非法 UUID → 400；inbox 未配 → 500；`expiresAt` 是毫秒且落在 (now, now+20min] |
| **Request spec** — `spec/requests/mobile_chat_spec.rb` | session 有效 → 302，且 `cw_conversation` 能被 `Widget::TokenService` 解开；session 过期/不存在 → 410 |
| **Request spec** — CORS | 带 `Origin: https://<esimgo-web>` 的 OPTIONS/POST 返回正确的 `Access-Control-Allow-Origin`（挂对命名空间的回归护栏） |
| **Service spec** — `spec/services/mobile_chat/identity_resolver_spec.rb` | 派生规则；业务 API 401/超时/5xx 都降级为匿名 |
| **集成** | 同一 `installationId` 调两次 `/session` → **复用同一个 `contact_inbox`**（`source_id` 稳定性回归护栏）；建会话 → `/mobile-chat` → 302 → `/widget` 拿到的是同一个 `contact_inbox` |

业务 API 用 stub（`stub_request` / `WebMock`），不依赖真实端点。

**两条回归护栏值得单列**，因为它们错的时候症状很隐蔽：
- **`source_id` 不稳定** → 不报错，只是每次打开客服都是新会话
- **命名空间挂错**（`/api` 而非 `/public/api`）→ 后端全对，但浏览器 CORS 预检失败

---

## 8. 部署配置

```bash
# Super Admin → Settings → App Configs，或 rails runner
MOBILE_CHAT_INBOX_ID=<inbox id>
NOVYRO_API_BASE_URL=https://...
NOVYRO_API_KEY=<x-api-key>
NOVYRO_SITE_ID=<site id>
```

`esimgo-web` 侧改两个值（具体配置键名以 `@/config/env` 里的 `customerSupportConfig` 为准）：

```
chatOrigin       : https://<chatwoot 域>       （原为 bridge 域）
sessionEndpoint  : https://<chatwoot 域>/public/api/v1/mobile_chat/session
```

**`chatOrigin` 必须和 `FRONTEND_URL` 完全一致**（含协议），否则前端的 `chatUrl.origin === config.chatOrigin` 校验会拒。
---

## 9. 与上游合并的考虑

改动落在：

| 类型 | 文件 | 冲突风险 |
|---|---|---|
| 新增 | `app/controllers/mobile_chat_controller.rb` | 无 |
| 新增 | `app/controllers/api/mobile_chat/sessions_controller.rb` | 无 |
| 新增 | `app/services/mobile_chat/*.rb` | 无 |
| 修改 | `config/routes.rb` | **低**（两处新增行） |
| 修改 | `lib/redis/redis_keys.rb` | **低**（一条常量） |
| 修改 | `config/installation_config.yml` | **低**（追加配置项） |

**没有覆盖上游文件** —— 合并时冲突面很小。

---

## 10. 后续阶段（不在本次范围）

1. **订单快照 / 工具** —— Captain 通过 `X-Chatwoot-Contact-Id` 反查 `contact.custom_attributes.app_token`，调业务 API
2. **产品目录 / 购买动作** —— 需要 Custom Tool + 卡片发送端
3. **`identityContinuityKey`** —— 本次固定返回 `{ confirmed: false }`，语义待定
4. **`resetChatIdentity`** —— 本次忽略；如需支持，表现为轮换 `anonymousProfileId` 后复用旧 contact

---

## 11. 已知风险与待定项

**R1 · CORS 全开**
`/public/api/*` 在 `cors.rb` 里是 `origins '*'` + `methods :any` —— 任何站点都能调这个 session 接口（会消耗业务 API 配额、写入 contact）。
bridge 有 origin 白名单，Chatwoot 侧没有。
**待定**：要不要在 controller 里校验 `Origin`？如果要，白名单配在哪（`InstallationConfig`）？
**本次倾向**：接受（接口本身不返回敏感数据，且要有效 token 才能拿到会员身份），但如果担心被刷，加一个 `MOBILE_CHAT_ALLOWED_ORIGINS` 白名单很便宜。

**R2 · `identifier` 格式是长期契约**
`member_<memberId>` / `guest_<installationId>_<anonymousProfileId>` 会**持久化进 `contact.identifier`**。格式一旦上线，改动等于重置所有联系人身份。
**本次倾向**：接受（已确认不关心旧匿名用户），但**上线前要先定死格式**。

**R3 · `app_token` 会进 Captain 的 prompt**
`contact.custom_attributes` 被 `captain/prompts/snippets/contact.liquid` 逐条渲染，所以 `app_token` 会出现在**每一轮对话的 system prompt 里**，发给 OpenAI。
**本次倾向**：接受（2026-10-08 讨论确认）。**但当 Captain 真正接入后要复核**：长随机串混在 prompt 里是否干扰模型判断。

**R4 · `MOBILE_CHAT_INBOX_ID` 单一 inbox**
本次只支持一个 inbox。如果将来官网 / App webview / 其它域需要**不同 inbox**，要改成按 Origin 映射（`InstallationConfig` 存一个 map）。

**R5 · 业务 API 失败静默降级**
token 有效但业务 API 挂掉时，客户会**静默变成匿名**（能聊但查不了订单）。
**待定**：要不要在响应里加一个字段让前端知道降级了？（会破坏 `.strict()` 契约，需要前端配合改）**本次不做**，但要在日志里留可观测信号。

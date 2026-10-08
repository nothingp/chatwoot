# 设计 · mobile-chat 卡片按钮的购买动作（前端接入）

- **日期**：2026-10-08
- **仓库**：`nothingp/chatwoot`（**本文档只描述外部客户端的待办改动；本次不改 `esimgo-web` / `esimgo-mobile`**）
- **状态**：待评审
- **前置**：`docs/superpowers/specs/2026-10-08-mobile-chat-native-design.md`

---

## 1. 背景与现状

套餐/产品**卡片已经能显示**，按钮点了**不会动**。

已经做完的（都在本仓库，已验证）：

| 事项 | 位置 | 状态 |
|---|---|---|
| 工具把推荐结果发成卡片消息 | `app/services/mobile_chat/captain_toolkit.rb#plan_cards`、`enterprise/lib/captain/tools/recommend_plan_tool.rb` | ✅ 已验：`content_type: cards`、`valid=true`、3 张卡、真实价格与 sku |
| 卡片渲染 | **stock** 自带：`app/javascript/widget/components/AgentMessageBubble.vue:131` → `shared/components/ChatCard.vue` → `CardButton.vue` | ✅ 不需要改 |
| 按钮动作 | `CardButton.vue` | ⚠️ 发 `postback`，**当前没有任何客户端监听** |

也就是说，剩下的全部是客户端侧的事。

## 2. 契约：widget → 宿主页

点按钮时，widget 发出去的东西（`app/javascript/widget/helpers/utils.js:8-13`）：

```js
window.parent.postMessage(
  `chatwoot-widget:${JSON.stringify({ event: 'postback', data: { payload } })}`,
  '*'
)
```

也就是宿主页收到的 `event.data` 是一个字符串：

```
chatwoot-widget:{"event":"postback","data":{"payload":"{\"goods_id\":14,\"sku_id\":1106}"}}
```

`payload` 是我们自己的 JSON 字符串，当前内容：

```json
{ "goods_id": 14, "sku_id": 1106 }              // goods_id = 我们的 product_id
```

`catalog_env` 只在 `contact.custom_attributes['catalog_environment']` 存在时才会带上（见 §5）。

**卡片与动作的允许字段**（`app/models/concerns/content_attribute_validator.rb`，超出即写入失败）：

- item：只能有 `title` / `description` / `media_url` / `actions`，且 `actions` **必填**
- action：只能有 `text` / `type` / `payload` / `uri`

## 3. 核心结论：两个客户端可行路径**不同**

这是本文档最要紧的一条 —— `CardButton.vue` 的 onClick 有一个 iframe 判断：

```js
if (this.action.type === 'postback') {
  if (IFrameHelper.isIFrame()) {            // isIFrame: window.self !== window.top
    IFrameHelper.sendMessage({ event: 'postback', data: { payload: this.action.payload } });
  }
}
```

| 客户端 | 载体 | `isIFrame()` | `postback` | 可行方案 |
|---|---|---|---|---|
| `esimgo-web` | `<iframe>` 嵌 `/widget` | **true** | ✅ 会发出 | **`postback`** —— 宿主页加监听 |
| `esimgo-mobile` | 顶层 `WebView` 加载 `chatUrl` | **false** | ❌ **完全不发** | **`link`** —— WebView 拦同源导航 |

> App 里既不能靠"自己收到自己发的消息"（因为它根本不发），也不能靠 `RNHelper`（那要求 `window.ReactNativeWebView`，Flutter 的 `webview_view` 没有）。

**推论：后端要按平台发不同的 action 类型。** 一次发两个按钮（一个 postback 一个 link）对一个客户端必然是死按钮，不采纳。

## 4. 每个客户端要改什么

### 4.1 `esimgo-web`：加 `postback` 监听

位置：`src/features/customer-support/customer-support-action-relay.ts`（已有 `novyro-customer-service-action:` 的中继，并列加一个分支）。

```ts
const WOOT_PREFIX = 'chatwoot-widget:';

function postbackPayload(event: MessageEvent): Record<string, unknown> | null {
  // 与现有中继同一套校验：origin 是唯一能确认发送方身份的依据
  if (event.origin !== customerSupportConfig.chatOrigin) return null;
  if (typeof event.data !== 'string' || !event.data.startsWith(WOOT_PREFIX)) return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(event.data.slice(WOOT_PREFIX.length));
  } catch {
    return null;
  }
  const payload = (parsed as { event?: unknown; data?: { payload?: unknown } })?.event === 'postback'
    ? (parsed as { data?: { payload?: unknown } }).data?.payload
    : null;
  if (typeof payload !== 'string') return null;

  try {
    return JSON.parse(payload) as Record<string, unknown>;
  } catch {
    return null;
  }
}
```

拿到 `{ goods_id, sku_id }` 后**复用现有那段"校验参数 → 打开收银台"的逻辑**（不要新写一套）：

- `goods_id` / `sku_id` 各一个且为正整数（与 App 的 `_isCheckoutAction` 同口径）
- 打开方式由产品定：新标签（`window.open(url, '_blank', 'noopener,noreferrer')`，与现有中继一致）还是同页跳转

### 4.2 `esimgo-mobile`：**不需要额外改动**

App 的 `_onNavigationRequest` 已经会拦"trusted origin + 路径恰好 `/app-actions/checkout` + 恰好一个 `goods_id`/`sku_id`"，并 `prevent` 掉导航、改走应用内收银台。

所以只要后端发 **`link`**：

```
{chatOrigin}/app-actions/checkout?goods_id=14&sku_id=1106
```

App 就自动接管 —— **前提**是 App 迁移时把 Chatwoot 域加进它的 trusted origin 集合（`AiAdvisorWebService.isTrustedWebOrigin`，属 App 迁移本身的改动，不属本文档新增）。

> 注意 Chatwoot **不需要**存在 `/app-actions/checkout` 这个路由：导航在 WebView 层就被 `prevent` 了，永远不会发出。

## 5. 本仓库要补的两处（本次不做，记录在此）

1. **`platform` 落库** —— 后端要按平台选 action 类型，就得知道调用方是谁。建会话时把 `params[:platform]`（`ios` / `android` / `web`）写进 `contact.custom_attributes['platform']`（一行，走 `MobileChat::ContactCredentials` 那条既有路径）。
2. **`catalog_environment` 落库** —— 若 web 的收银台校验要求"恰好 `catalog_env,goods_id,sku_id` 三个参数"，就把 `params[:catalogEnvironment]` 一并写进 `contact.custom_attributes`。现在 payload 里不带它，是因为会话没存过这个字段。

`CaptainToolkit#sku_action` 已经预留了读取逻辑，落库后自动生效。

## 6. 测试

| 层 | 怎么验 |
|---|---|
| 卡片渲染（已完成） | 容器内发一条 cards 消息 → `valid=true`、`items` 键只有允许的四个（已在 81 实例验过） |
| Web | 在 iframe 里点按钮 → 收银台打开，且**客服面板没有被导航走** |
| App | 在 WebView 里点按钮 → **应用内**收银台打开，且聊天页停在原处（证明 `prevent` 生效） |
| 按钮没反应 | 先看 `isIFrame()` 那条：App 里如果后端错发成 `postback`，症状就是"点了完全没反应、控制台也没有报错" |

**已知限制**：Playground 没有 conversation，工具发不出卡片（会降级为返回 JSON 文本）—— 卡片只能在真实会话里看到。

## 7. 不在范围

- 移植 `patches/chatwoot-local.patch` 里的 `chatwoot-…` → `novyro-…` 两跳中继，或重建承载页（那是本次迁移刚拆掉的东西）
- 搜索结果（`search_products`）的卡片：搜索结果只有产品级价格、没有 `sku_id`，做不出可购买的按钮
- 套餐/推荐以外场景的卡片发送端
- 客户端改动本身（本文档是待办清单，改的时候再开各自仓库的任务）

## 8. 风险与待定

- **R1 · 按平台选 action 类型**：依赖 §5 的 `platform` 落库。在落库之前，卡片只能选一种（会牺牲其中一个客户端）。
- **R2 · `catalog_env` 的来源**：见 §5.2。若 web 校验强制三参数，未落库时 `postback` 会被 web 丢弃 → 症状同样是"点了没反应"。
- **R3 · Web 的打开方式**：`_blank` 新标签 vs 同页跳转，取决于产品对"客服面板要不要保留"的期望；现有中继用的是 `_blank` + `noopener,noreferrer`。
- **R4 · 价格货币**：卡片按钮文案目前固定取 `USD`（另有 4 种币种的原始数据）。如果客户的实际货币不是 USD，展示会有偏差 —— 需要把建会话时的 `currency` 一并落库后再按它取价。

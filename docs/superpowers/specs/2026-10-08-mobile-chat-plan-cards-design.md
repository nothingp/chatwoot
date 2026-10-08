# 设计 · mobile-chat 套餐卡片（对齐 App 的 novyro_plan_group 契约）

- **日期**：2026-10-08
- **仓库**：`nothingp/chatwoot`（**客户端改动只在 §7 列出，本次不改** `esimgo-mobile` / `esimgo-web`）
- **状态**：待评审
- **前置**：`2026-10-08-mobile-chat-native-design.md`、`2026-10-08-mobile-chat-card-actions.md`

---

## 1. 背景

卡片现在**发得出去、但形状是自造的**：`CaptainToolkit#plan_cards` 产出 `title` + `description`（"from USD 9.90"）+ 每个 SKU 一个 `postback` 按钮，字段白名单卡在 `content_attribute_validator.rb:3`（item 只允许 `title/description/media_url/actions`）。App 端认的是另一套契约，且那套契约**已经冻结在 App 的测试里**。

App 侧的契约（唯一权威）：

- 模型：`esimgo-mobile/lib/models/chatwoot_client_models.dart` 的 `ChatwootCardItem`（读 `badge` / `facts`，按 icon 解析 `validityDays` / `dataLabel` / `priceLabel`）
- 样本：`esimgo-mobile/test/chatwoot_client_models_test.dart:248` "parses the complete Novyro plan-group response contract"

这套契约原先由 ai-bridge 产出，去 ai-bridge 之后必须落回本仓库：

| 原实现 | 位置 |
|---|---|
| 卡片组装（variant / badge / facts / action） | `customer-service-platform/apps/ai-bridge/src/purchaseCards.js`（`buildPurchaseCards` / `cardFor` / `factsFor`） |
| 文案字典 41 语言 + 回退链 | `apps/ai-bridge/src/mobileChat/purchaseCopy.js`、`localeCopy.js` |
| 严格校验器 | `customer-chatwoot/app/models/concerns/content_attribute_validator.rb`（打过补丁的 Chatwoot fork） |
| 工具契约与对账 | `apps/ai-bridge/src/mcp/toolCatalog.js`（`create_purchase_action`）、`src/tools/supportContextStore.js`、`src/mcp/toolRuntime.js:110` |

**目标**：本仓库发出的卡片消息与 App 的契约逐字段一致。

**这张卡谁画的**：App 的 1.0.33 / 1.0.34 原生顾问页 —— `esimgo-mobile/lib/screens/home/ai_plan_advisor_screen.dart:569` 把 `message.cards` 交给 `_RecommendedPlanGroup`（:1345），再经 `_PlanCardViewData.fromCard(ChatwootCardItem)`（:1768）画成主卡与备选。**读的就是 Chatwoot 消息**，所以本次改动到位就能复刻这张卡（渲染细节见 §2.1）。

main 分支已把顾问页换成 WebView（载 `/mobile-chat` → stock widget，`app/controllers/mobile_chat_controller.rb` 只做一次 302），那条路上卡片由 `ChatCard.vue` 画，没有 badge / icon facts / 全宽 CTA —— 要看到截图那张卡，得用带原生顾问页的那条发布线，或把 UI 迁回 main（见 §7）。

## 2. 契约：服务端 → 客户端

消息：`content_type: :cards`，`content` 必须非空（`AgentMessage#shouldDisplayAgentMessage` 返回 `content`，空则整条气泡被 widget 跳过），`content_attributes`：

```json
{
  "variant": "novyro_plan_group",
  "items": [{
    "title": "日本 7日 10GB 总量套餐",
    "description": "7天日本专属行程，10GB总量。",
    "media_url": "",
    "country_image": "https://.../JP.svg",
    "badge": "最佳匹配",
    "facts": [
      {"icon": "wifi",     "label": "流量",   "value": "10 GB"},
      {"icon": "calendar", "label": "有效期", "value": "7天"},
      {"icon": "wallet",   "label": "价格",   "value": "USD 16.99"}
    ],
    "actions": [{
      "type": "link",
      "text": "日本 7日 10GB 总量套餐",
      "uri": "https://<frontend>/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod"
    }]
  }]
}
```

约束（照 `customer-chatwoot` 的校验器，裁掉 web 变体与 digest 后的部分）：

| 层 | 约束 |
|---|---|
| 顶层 | `content_attributes` 键恰好 `{variant, items}`（重复键、未知键都拒绝） |
| items | 1..5 项 |
| item 必含 | `title`(≤160) / `description`(≤500) / `media_url`(**必须是空串**) / `badge`(≤40) / `facts` / `actions` |
| item 可选 | `country_image`（空串或 https、无 userinfo/fragment、≤2048） |
| facts | 1..3 项，键恰好 `{icon,label,value}`；`icon ∈ {wifi, calendar, wallet}`；`label` ≤40、`value` ≤120 |
| actions | **恰好 1 个**，键恰好 `{type,text,uri}`；`type == "link"`；`text` ≤120 |
| uri | http/https、有 host、无 userinfo/fragment；path **恰好** `/app-actions/checkout`；query **恰好** `{goods_id, sku_id, catalog_env}` 三个（id 为 1..2^53-1 的数字串，`catalog_env ∈ {dev,test,prod}`） |
| 文本 | 非空、无控制字符（`\u0000-\u001f\u007f-\u009f`） |

facts 取值（`factsFor`）：

- 流量：`unlimited` → `copy.unlimited`（"无限流量"），否则 `"{dataSizeGb} GB"`
- 有效期：`copy.dayUnit` 里的 `{n}` 替换为天数（zh_CN 是 `"{n}天"`，en 是 `"{n} days"` —— 空格与否内建在模板里，渲染层不做 locale 判断）
- 价格：`"#{currency} #{金额}"`，金额固定两位小数

`badge`：`placement == "primary"` → `copy.primary`（"最佳匹配"），否则 `copy.alternative`（"备选方案"）。

**不发**：`customer_support_content_sha256`（bridge 的投递去重元数据，本路径不需要；App 侧是可选字段）。**不做** `novyro_web_plan_list`：原实现后来把 web 入口也统一到 bridge 中转页、两端共用 `novyro_plan_group`（`supportContextStore.js:36` 的注释记录了这次收敛），web 变体已是死代码。

### 2.1 App 1.0.34 实际渲染什么（决定了服务端该给什么）

| 界面元素 | 来源 | 服务端要注意 |
|---|---|---|
| 主卡 / 备选 | **`items` 的顺序**：`plans.first` 是主卡（全宽 CTA），`plans.skip(1)` 是两列备选（`advisorPlanAlternatives`） | 主推的 SKU **必须排在第一位** |
| 徽标"最佳匹配" | App 的 `l10n.advisorBestMatch`（`ai_plan_advisor_screen.dart:1471`） | `badge` 字段**不渲染**，但契约要求它存在，照发 |
| CTA 文案"Choose this plan" | App 的 `l10n.advisorChoosePlan`（:1560） | `actions[0].text` **不渲染**，但契约要求，照发 |
| 流量值 / 天数 | `facts` 里 `icon: wifi` / `calendar` 的 `value`（`chatwoot_client_models.dart:464`；天数是"值里第一个整数"，再经 App 的 `advisorDayCount` 模板重画） | **值会被原样显示**（"无限流量"这种必须本地化）；天数只需可解析 |
| 目的地与国旗 | `_cardDestination(card.title, ...)`：从标题里剥掉流量与天数得到目的地，再查 `CountryDataMap`（:1768） | `title` 写成**产品名（目的地）**，即原 `cardFor` 的 `productName`；不要把流量/天数拼进标题 |
| 点击 | `onAction(card.actions.firstOrNull)` | 必须是 `link` + uri（App 在 WebView/原生层接管 `/app-actions/checkout`） |

facts 缺失时 App 会退化成用正则从 `title + description + action labels` 里猜流量与天数（`_firstMatch`）—— 能用，但正是"标题一乱、卡片就乱"的来源，所以 facts 必须发全。

## 3. 数据流：模型决策，服务端对账

原设计的要点是 —— **模型是决策者（选哪个 SKU、primary 还是 alternative、理由怎么写、CTA 文案叫什么），但不是数据源**（数字与 id 都来自工具返回，且被服务端对账）。照搬：

```
客户：去日本 7 天，有推荐吗
 → LLM 调 recommend_plans(country_code, billing_period)          ← 改：只回数据，不再发卡
 ← { ok: true, count: 1, plans: [{ product_id, name, country_*,
                                  skus: [{ sku_id, data_size_value, data_size_unit,
                                           data_unlimited, billing_period_days, price }] }] }
 → LLM 自己挑 SKU（第一个是主推）、写推荐理由与 CTA 文案
 → LLM 调 create_purchase_action(product_id, sku_ids, reason, label)     ← 新工具，一次一组
 ← 服务端拿 product_id 去上游拉详情、逐个核对 sku 存在 → 按 locale 与顺序组卡 → 发一条 cards 消息
 ← "Posted 3 plan cards…"
```

**工具契约**

| 工具 | 参数 | 说明 |
|---|---|---|
| `recommend_plans` | `country_code`, `billing_period` | 不改签名；改的是**不再发卡**，把带 `sku_id` 的目录数据交回模型。现在真实会话里它只回 "Posted N plan cards…"，模型根本看不到 SKU |
| `create_purchase_action` | `product_id`, `sku_ids`（有序数组，1..5）, `reason`, `label` | 一次一组：**顺序即主次**，`sku_ids.first` 是主推。`reason` → 主卡 description，`label` → 主卡 CTA 文案（web 的 stock widget 会显示这两个；App 1.0.34 不显示） |

**与原工具形状的偏差（有意）**：原 `create_purchase_action` 是"一个 SKU 一次调用"（`toolCatalog.js:69` 五个必填参数），多张卡靠 bridge 在同一轮攒够 action 再投递（`purchaseCardDelivery.js`）。在 Chatwoot 里复现"攒够再发"要么引入同轮状态、要么改写已投递的消息，两者都不值 —— 改成**一次调用一组**：一条消息、顺序即主次，与 App 的渲染规则（`plans.first` 是主卡）天然一致。`placement` 参数因此取消（顺序就是 placement）；`sku_ids` 用现有 `parameter` DSL 的数组类型即可表达（ruby_llm 2.0 会生成 `{type:'array', items:{type:'string'}}`）。

**备选卡的文案**：模型写的 `reason`/`label` 只用在主卡；第 2..n 张用 `copy.description` / `copy.cta` 兜底（App 的备选卡本来也不显示这两者）。

**服务端对账**（本次选择"无状态拉取复核"）：`create_purchase_action` 拿到 `product_id` 后自己调 `PRODUCT_DETAILS_PATH`，要求 `sku_id` 出现在返回的 `skus` 里；**卡片的流量/有效期/价格全部取自这次上游返回**，不采用模型给的任何数字。sku 不存在 → `{ ok: false, error: ... }`，模型照现有约定（不报具体套餐）回答；不发卡。

**顺序即主次**：`items` 按 `sku_ids` 的顺序排，第一张是主卡（badge 取 `copy.primary`、description 取模型给的 `reason`、CTA 取模型给的 `label`），其余取 `copy.alternative` / `copy.description` / `copy.cta`。

> 与 ai-bridge 的差别：那边是 `supportContextStore` 把本会话的目录结果落库（10 分钟 TTL、最多 3 条），`createVerifiedPurchaseAction` 只接受本会话出现过的 product+sku。本次不复制这套状态：**不存在会失败、数字不可伪造**这两条已经拿到；剩下没管住的是"这个 SKU 是不是真的回应当前问题"（相关性问题），交给 prompt。

**上游语言与币种**：`recommend_plans` 与 `create_purchase_action` 都要把 contact 上落的 `locale` / `currency` 作为 **header** 传给上游（原实现 `publicHeaders`，`appClient.js:133`），这样上游返回的语言与价格就是我们直接要用的那份。缺失时回落（locale → en，currency → USD）。

**`catalog_env` 是必填的第三个 query**：取 contact 的 `catalog_environment`，缺失回落部署配置（原实现 `context.catalogEnvironment || config.novyroCatalogEnvironment`）。缺了它按钮就是废的，所以必须有兜底而不是静默省略。

## 4. 文案

**位置**：`config/mobile_chat/card_copy.yml`（41 语言，从 `purchaseCopy.js` 整体搬来）+ `app/services/mobile_chat/card_copy.rb`（薄 loader）。回退链照搬 `localeCopy.js`：**精确 appLocale → 语言前缀 → en**；`en` 缺失直接抛错（原实现的注释说得很清楚：缺 en 会把崩溃推迟到远处某个取值点）。

**查表前必须先把客户端给的 locale 规范化**：回退链前面还有一步 `normalizeLocale`（`apps/ai-bridge/src/mobileChat/language.js:207`），把客户端原始值变成本字典所键的 appLocale —— 先 trim、`-`→`_`、小写，再按字典自身的键精确匹配（`zh_hant`→`zh_Hant`、`pt_br`→`pt_BR`），再走语言族（`zh` 带 `hant/tw/hk/mo` 限定取 `zh_Hant`、否则 `zh_CN`；`pt` 取 `pt_BR`，限定为 `pt` 时取 `pt_PT`；`es`+`mx` → `es_MX`；`fr`+`ca` → `fr_CA`），再退到裸语言（`en_GB`→`en`、`de_DE`→`de`，`fil→tl`/`iw→he`/`in→id`/`nb→no`/`nn→no` 这些旧别名也在这步），未知一律 `en`。**少了这一步就是客户可见的回退**：esimgo-web 发的是裸 `pt`（`esimgo-web/src/lib/i18n/locales.ts:55`，`customer-support-session-service.ts:31` 只把连字符换成下划线），裸 `pt` 既不是 `pt_BR` 也不是 `pt_PT`、前缀也取不到 `pt`，于是葡萄牙语客户拿到的是英文卡面（Data / Validity / Price / View plan）—— 正是本节要避免的那种回退。

**为什么不用 Chatwoot 的 I18n**：

1. 卡片在 **Captain 的 job** 里生成，没有请求上下文 —— Chatwoot 自己的 Captain 也得手动包 `I18n.with_locale(account.locale)`（`response_builder_job.rb:99`）。而我们要的是**客户**的语言（contact 上的 `locale`），不是 account 的语言。
2. 语言集合对不上：Chatwoot 后端 42 种 enabled（`config/initializers/languages.rb`，`zh`/`hi` 被 disabled），没有 `ky`/`tl`/`ms`/`hr`/`bn`/`es_MX`/`fr_CA`/`pt_PT`，`zh_Hant` 在它那儿叫 `zh_TW`。而 `I18n.enforce_available_locales` 默认开着，想 `with_locale` 一个不存在的 locale 就得往 `LANGUAGES_CONFIG` 里加 —— 那是上游文件，还兼着 `Account#locale` 的整数枚举。
3. 这些是**购买业务文案**，不是 Chatwoot 的 UI 文案；放进 `config/locales/*.yml` 会被 Crowdin 同步当 Chatwoot 的文案处理，评审流程也不在我们手里。

**字典内容**：41 种照搬，但**只搬卡片用到的键**：`primary` / `alternative` / `data` / `unlimited` / `validity` / `dayUnit` / `price` / `cta` / `description` / `plan`。bridge 自己往对话里写的那几段回复文案（`conclusion` / `advisorLead` / `safeReply` / `purchaseUnavailable`）不搬 —— 那段文字现在由模型写、由工具返回值负责。

其中只有 `zh_CN` 与 `en` 是人工产出的，其余 39 种是模型生成、未经母语审校（原文件头部自己标注了，并点名 `dayUnit` 模板在 ar/ru/pl/cs 等语言上数词形态不严谨）。照搬是因为这些译文**线上已在用**，少搬等于让那些语言的用户相对现状回退到英文；未审校的条目在 YAML 里注明，后续交产品/本地化逐语言复核。

**真正被显示的是哪些值**（§2.1）：App 1.0.34 只把 facts 的 `value` 原样画出来，所以 `unlimited`（"无限流量"）这类值必须本地化；`dayUnit` 它不直接用（天数是自己按 `{n}天` 模板重画的），但仍要发成可解析的整数文本；`primary`/`alternative`/`cta`/`description` 是为契约完整与其它渲染方（widget、未来版本）保留的。

**模型给的自由文本要过 sanitizer**：`reason` 与 `label` 是模型写的，直接进购买卡片。照搬 `purchaseCards.js#sanitizePublicReply` / `chatFriendlyPurchaseReply` 的判据：长度上限、无 URL、无 markdown（表格/标题/列表）、emoji ≤1、无控制字符；不合格回落 `copy.description` / `copy.cta`。

## 5. 本仓库改动清单

| 文件 | 改动 |
|---|---|
| `config/mobile_chat/card_copy.yml`（新增） | 41 语言字典，只取卡片用到的键（见 §4） |
| `app/services/mobile_chat/card_copy.rb`（新增） | `for(locale)`：精确 → 前缀 → en；sanitizer 也放这里 |
| `app/services/mobile_chat/captain_toolkit.rb` | 新增 `purchase_actions(params)`（复核 + 组卡）；`fetch_json` 按 contact 的 `locale` / `currency` 追加 header（一处改动，所有上游调用都带上）；删除 `plan_cards` / `plan_card` / `sku_action` / `sku_label` / `from_price_label` |
| `app/models/concerns/content_attribute_validator.rb` | 加 `novyro_plan_group` 分支（自 `customer-chatwoot` 补丁裁剪：去掉 web 变体、去掉 digest 校验） |
| `enterprise/lib/captain/tools/recommend_plan_tool.rb` | 去掉发卡，只回数据 |
| `enterprise/lib/captain/tools/create_purchase_action_tool.rb`（新增） | 新工具：校验参数 → 调 toolkit → 发卡（复用 `post_cards`） |
| `config/agents/tools.yml` | 加 `create_purchase_action` 条目（`resolve_tool_class` 按 `id.classify` 找 `Captain::Tools::CreatePurchaseActionTool`） |
| `enterprise/lib/captain/tools/mobile_chat_tool.rb` | `post_cards` 改为发 `variant: 'novyro_plan_group'`；`content` 仍用标题拼（空 content 会让 widget 整条不显示） |

## 6. 测试

| 层 | 验什么 |
|---|---|
| validator spec | `variant: novyro_plan_group` 的接受；逐条拒绝：缺 `badge`/`facts`、facts 为 0 或 4 项、icon 非法、`media_url` 非空、action 数量 ≠1、`type != link`、uri path/query 不对、超长文本、控制字符、未知顶层键 |
| toolkit spec | 复核失败（sku 不在上游返回里）→ `{ok:false}`；卡片字段全部取自上游（模型给的数字被忽略）；`sku_ids` 顺序 → items 顺序、第一张取 `copy.primary`；超过 5 个截断；uri 的三个 query；facts 三值；locale 回退（`zh_Hant` 命中繁体、未知 locale 落 en） |
| tool spec | 成功发卡（`content_type: cards`、`variant`、items 数）；无 conversation 时降级为返回 JSON（Playground） |

## 7. 客户端待办（不在本仓库）

| 客户端 | 现状 | 要做什么 |
|---|---|---|
| `esimgo-mobile` | 1.0.33 / 1.0.34 的原生顾问页**已经在读 Chatwoot 卡片**（`ai_plan_advisor_screen.dart:569`），缺的只是服务端字段；main 已换成 WebView（载 `/mobile-chat` → stock widget，`mobile_chat_controller.rb` 只做一次 302） | **不改就有效**：本次服务端改完后，带原生顾问页的那条发布线直接显示成截图那样。若要 main 也有同款外观，得把这套 UI 迁移回来（否则只能看 widget 的简版卡片） |
| `esimgo-web` | iframe 嵌 widget；`customer-support-action-relay.ts` 只监听 `postback` | 按钮改成 `link` 后，iframe 里点它会开新标签导航到 `{frontend_url}/app-actions/checkout` —— **Chatwoot 没有这个路由，会 404**（原实现能work是因为 bridge 自己提供了中转页）。需要拦点击或补中转页 |

App 侧 WebView 会拦 trusted origin + `/app-actions/checkout` 的导航，**不用改**。

## 8. 不在范围

- 客户端改动本身（§7 是待办清单）
- `search_products` 的卡片（搜索结果只有产品级价格、没有可购买的 sku）
- `novyro_web_plan_list` 变体（原实现已废弃）与 `customer_support_content_sha256`
- 套餐/推荐以外场景的卡片发送端

## 9. 风险与待定

- **R1 · web 会 404**：见 §7。本次不做，但上线前必须由 web 端补上，否则 web 用户点按钮页面直接跳走。
- **R2 · 现有 Scenario 指令要跟着改**：`recommend_plans` 不再发卡，指令里"用它来推荐套餐"的写法要改成"先拿数据、再用 `create_purchase_action` 下单"（`captain-materials/apply_captain_scenarios.rb` 里现在引用的是前者）。
- **R3 · 39 种未审校译文**：照搬 = 与现状一致；但这是**直接面向客户的购买文案**，被本地化挑出问题时改 YAML 即可。
- **R4 · 币种**：价格 fact 用 contact 的 `currency`（缺失回落 USD）。上游支持 5 种币种，contact 上落的是客户端声明的那个。
- **R5 · `label` 由模型写**：CTA 文案会随模型浮动。sanitizer 只保证安全与长度，不保证口径一致；若上线后发现文案飘，改成服务端生成（用 SKU 数据拼）。
- **R6 · 卡片数量**：上限 5（照 `MAX_CARDS`）。模型一次能否挑出 5 个以上 SKU 由它自己决定，服务端只截断。

# Captain 导入材料

从 `customer-service-platform/knowledge-base/customer-support/esim-support-manual.en.md` 拆出来的材料，准备导入 Chatwoot Captain。

**本地材料，不属于上游 Chatwoot 仓库**（和 `agent-bot/` 一样是未跟踪目录）。

---

## 为什么拆

原手册 39,477 字符，内部是严格的两种内容混在一起：

```
### 客户问题
   <答案正文>                            ← 知识，该进 Documents
   **Support handling:** <给 AI 的规则>  ← 规则，该进 Guardrails / Scenarios
```

49 个小节里 45 个带 `Support handling` 段，剩下 4 个是 §0（本身就是规则）。**切分是机械的，用正则就能做，不需要 LLM 判断。**

不拆的后果（实测过）：规则会被一起切成 FAQ，`faq_lookup` 检索到后可能**把内部策略当客户答案说出去**。实测导入原文档生成的 50 条 FAQ 里，前 6 条有 4 条是"回答客户时有哪些基本规则"这种。

---

## 目录

| 文件 | 内容 | 去哪 |
|---|---|---|
| `knowledge/esim-support-knowledge.md` | 20,575 字符，§1–§11 答案正文（已剥规则） | Captain → Documents（1 个文档，自动生成 FAQ） |
| `rules/00-global.md` | 全局禁忌 + 转人工规则（手写压缩） | Captain → Settings → Guardrails |
| `rules/01-product-compatibility.md` | 22 条，产品与兼容咨询 | Captain → Scenarios → 产品与兼容咨询 |
| `rules/02-usage-install.md` | 13 条，使用与安装 | Captain → Scenarios → 使用与安装 |
| `rules/03-orders-refunds.md` | 10 条，订单与退款 | Captain → Scenarios → 订单与退款 |
| `rules/_raw-all-rules.md` | 全部 45 条原文 | 只留档，不进 Captain |

---

## Scenario 为什么是 3 个

按「**客户一次对话会连续问到的范围**」划，不按文档章节划：

| Scenario | 覆盖原文 | 边界理由 |
|---|---|---|
| 产品与兼容咨询 | §1 §2 §3 §10 | 客户必然连着问「我的手机支持吗 + 有日本套餐吗」。**注意这里不只是售前** —— 买完发现设备不兼容问的是同一类问题，所以不叫「售前咨询」 |
| 使用与安装 | §4 §5 §6 | 都是「买完了但用不起来」：装不上、二维码、到目的地连不上 |
| 订单与退款 | §7 §8 §9 | 都需要订单证据，且退款涉及审批与转人工 |

**为什么不更细**：每多一个 Scenario 就多一次 LLM 交接（延迟 + token）。`§2 设备兼容`（1.2K 字符）和 `§6 联网排障`（1.6K）单独成篇不值得。

**为什么转人工不单独建 Scenario**：Captain 的主 assistant **永远有 `handoff` 工具**（`Captain::Assistant#agent_tools` 里硬编码），原设计里「只有加载了 handoff skill 才授权」那个门禁**实现不了**。所以「什么时候该转」必须常驻 —— 放在 `00-global.md` 里。

---

## ⚠️ 现阶段的限制

**很多规则是「先查订单/产品证据」，而 Captain 目前没有任何业务工具** —— 那 7 个 MCP 工具（`list_orders` / `get_order_details` / `recommend_plans` / `search_products` / `get_product_details` / `create_purchase_action` / `request_human_handoff`）还在 ai-bridge 里。

后果：规则写进 Scenario 是**无害的**（模型会照指令去查，没有工具就只能转人工），但**不完整** —— 等于「知道该查什么，但没工具查」。

等 Custom Tools 做好了，**同一个 Scenario 不用改 instruction 就能真正生效**。

---

## 导入顺序

1. **先知识** —— Captain → Documents → 上传 `knowledge/esim-support-knowledge.md`（选 URL 或 PDF 之外的路子见下）
2. 等 FAQ 生成完，检查条数与覆盖
3. **再 Guardrails** —— `rules/00-global.md` 的条目逐条粘进 Settings → Guardrails
4. **最后 Scenarios** —— 新建 3 个，各自把对应文件的「处理规则」段整段贴进 Instruction

### 关于 Documents 的上传方式

Captain 的 **Documents 页面 UI 只有 URL 和 PDF**。Markdown 有两条路：

- **Playground → 贴内容 → Save as Document**（UI 唯一入口）
- **直接调 API / runner**：`assistant.documents.create!(markdown_content: ...)`

另外 `Concerns::CaptainMarkdownDocumentable::MARKDOWN_MAX_LENGTH` 原本是 **10,000 字符**，这份知识文档是 20,575 —— 需要放宽（在 32.236.75.213 那台上已经通过容器初始化器放宽到 50,000，但**重建容器即失效**）。

### ✅ 已实测：不用再切

2026-10-08 在 32.236.75.213:81 上用 `esim-support-knowledge.md`（20,441 字符，45 个小节）实测：

```
45 个小节 → 45 条 FAQ，1:1 完整覆盖，全部 1536 维嵌入成功
```

**FAQ 密度按「小节数」算，不按字符数** —— 每条 `###` 小节恰好产出一条 FAQ。

> 之前误判过一次：拿「39K 含规则 → 50 条」按字符比例推算，得出「20K → 25 条、一半没覆盖」。错在忽略了那 39K 里有 19K 规则也参与计数。剥掉规则后比例不变。

**副作用确认**：剥离规则后，生成的 45 条全是知识性问题，不再出现"回答客户时有哪些基本规则"这类污染。

### ⚠️ FAQ 语言

FAQ 生成的语言**跟着 account locale 走，不跟文档走**：

```ruby
# FaqGeneratorService
@language = document.account.locale_english_name
```

account locale 是 `zh_CN` 时，prompt 写的是 "Generate the FAQs only in the chinese" —— **英文文档会生成中文 FAQ**。`Captain::Document` 没有 locale 字段，一份文档只能出一种语言。

---

## 重新生成

`knowledge/` 和 `rules/01-03`（含 `_raw-all-rules.md`）是从源手册机械切出来的。如果源手册更新了，重新切一遍即可。`rules/00-global.md` 是手写压缩的，需要人工维护 —— 用 `_raw-all-rules.md` 核对有没有漏约束。

# Captain LLM Provider 迁移：OpenAI → 阿里云 DashScope

- 日期：2026-10-09
- 状态：待评审
- 分支：`feat/captain-llm-provider-migration`（基于 `develop`）
- 范围：`:81` 对比实例验证 → 生产栈

---

## 1. 背景与动机

Captain 当前所有 LLM 调用走 OpenAI。迁移到阿里云 DashScope（百炼）的动机有两层：

1. **成本**。`qwen3.8-flash` 对比当前实际在用的模型，输出端便宜 4×（对 gpt-4.1-mini）到 37×（对 gpt-5.2）。详见附录 C。
2. **可预见的返工**。模型下线是常态（本轮评估期间已撞到三个：`deepseek-v4-flash`、`deepseek-v4.1-flash`、`qwen3-max`）。而当前架构下，**每次换 provider 或换模型 id 都要改代码 + 重建镜像（约 40 分钟）**——因为模型 id 写死在 repo 文件里，还有一处硬编码在 Ruby 中。

本设计同时解决这两件事：换到 DashScope，并把"以后换 provider / 换模型"从"改代码 + 重建"降级为"改配置 + 重启"。

## 2. 目标与非目标

### 目标

- Captain 的 chat 与 embedding 全部由 DashScope 提供
- 切 provider（DashScope ↔ OpenAI）或换模型 id，对 **9 个 chat feature 与 embedding** = 改配置 + 进程重启，**不改代码、不重建镜像**
- 向量迁移零内容损失

> ⚠️ 「不改代码」有一个例外：**`pdf_faq_generation` 不可移植**。它的 `fileid://` 引用方式是 DashScope 专有，切回 OpenAI 需改代码（§7.5、§12）。这是选路 B 的已知代价，不是遗漏。

### 非目标

- 不改 Captain 的产品行为（prompt、工具集、转人工策略、FAQ 审批流）
- 不做多 provider 并存（一个 installation 同时只有一个 active endpoint）
- 不重构上游 OSS 的对外契约

## 3. 范围

| 环境 | 部署方式 | 说明 |
|---|---|---|
| `:81` 对比实例 | 自建镜像（`deploy/upstream-comparison/deploy.sh`） | 先验证 |
| 生产栈 | 同样是本仓库构建的自建镜像 | 验证通过后推 |

**验收标准：功能跑通。** 不做 OpenAI vs Qwen 的检索质量基线对比（见 §12 未决项）。

## 4. 现状架构与阻塞点

### 4.1 当前可运行时配置的面

`config/installation_config.yml` 中与模型相关的项只有 4 个：

| 配置项 | 实际作用域 |
|---|---|
| `CAPTAIN_OPEN_AI_API_KEY` | RubyLLM 全局 key + `with_api_key` 上下文 + `LegacyBaseOpenAiService` |
| `CAPTAIN_OPEN_AI_ENDPOINT` | RubyLLM 全局 base（`"#{endpoint}/v1"`）+ `base_task_service#api_base` + `LegacyBaseOpenAiService#uri_base` |
| `CAPTAIN_OPEN_AI_MODEL` | **只对 `conversation_completion`** 生效；外加未开 `captain_integration` 账号的 agents 兜底 |
| `CAPTAIN_EMBEDDING_MODEL` | `EmbeddingService.embedding_model` |

其余模型来源是 `config/llm.yml`（每个 feature 的 `default` 与白名单）。

### 4.2 三个硬阻塞

> 这三个阻塞针对的是「**切 provider 不改代码**」这个目标。仅说"要从 OpenAI 换到 DashScope"的话，只有阻塞 1、2 拦路（阻塞 3 反而是好事——见下）。

| # | 阻塞 | 位置 |
|---|---|---|
| 1 | 模型 id 写在 repo 文件里，启动时 `YAML.load_file` 成冻结常量 | `config/llm.yml` → `Llm::Models::CONFIG` |
| 2 | assistant 的模型硬编码在 Ruby | `lib/llm/feature_router.rb:4` `CAPTAIN_V2_ASSISTANT_MODEL = 'gpt-5.2'` |
| 3 | `LegacyBaseOpenAiService`（PDF/音频）与 RubyLLM 共用 endpoint/key | `enterprise/app/services/llm/legacy_base_open_ai_service.rb#uri_base` |

阻塞 2 最隐蔽：**`CAPTAIN_OPEN_AI_MODEL` 设成什么都不影响 assistant**——`FeatureRouter#model_and_source` 的 `captain_assistant_model` 会在它之后仍被采用（当账号开了 `captain_integration` 且无账号级 override 时）。而账号级 override 必须命中 `llm.yml` 白名单（`Llm::Models.valid_model_for?`），绕回阻塞 1。

阻塞 3 在本次选路 B（PDF 也换 DashScope）之后**不再是阻塞，反而成了便利**：无需拆分独立配置线，见 §5。

### 4.3 两个运维阻塞

| # | 阻塞 | 说明 |
|---|---|---|
| 4 | embedding 维度 | `CAPTAIN_EMBEDDING_MODEL` 没有维度配置入口；DashScope 的默认维度与 `vector(1536)` 不符 |
| 5 | `role: developer` | RubyLLM 的 chat_completions 协议默认发 `developer`；DashScope 全系拒绝 |

阻塞 5 已在本仓库依赖的版本中确认：`ruby_llm (2.0.0)`，源码 `lib/ruby_llm/protocols/chat_completions/chat.rb` 为

```ruby
@config.openai_use_system_role ? 'system' : 'developer'
```

而 `Llm::Config` 设了 `config.openai_protocol = :chat_completions`，未设 `openai_use_system_role`。

**结论：当前架构下切 provider = 改 `llm.yml` + 改 Ruby + 重建镜像 + 重算向量。**

## 5. 目标架构

**单条配置线**——`CAPTAIN_OPEN_AI_ENDPOINT` 一个值同时服务三条技术路径：

```
RubyLLM (chat + embedding)  ─┐
Agents SDK (assistant)      ─┼─→ CAPTAIN_OPEN_AI_ENDPOINT → DashScope
ruby-openai SDK (PDF/audio) ─┘
```

四条读 endpoint 的代码路径全部收敛到同一个 URL：

| 路径 | 处理方式 | 结果（endpoint = `https://dashscope.aliyuncs.com/compatible-mode`） |
|---|---|---|
| `Llm::Config#configure_ruby_llm` | `"#{endpoint.chomp('/')}/v1"` | `.../compatible-mode/v1` |
| `Captain::BaseTaskService#api_base` | `"#{endpoint.chomp('/')}/v1"` | 同上 |
| `config/initializers/ai_agents.rb` | `"#{endpoint.chomp('/')}/v1"` | 同上 |
| **`Llm::LegacyBaseOpenAiService#uri_base`** | **原样传，SDK 自动补 `/v1`** | 同上 |

最后一条是关键：`ruby-openai (7.3.1)` 的 `lib/openai/http.rb#uri`：

```ruby
def uri(path:)
  if azure?
    ...
  elsif @uri_base.include?(@api_version)
    File.join(@uri_base, path)
  else
    File.join(@uri_base, @api_version, path)   # @api_version = "v1"
  end
end
```

**因此不需要为 legacy 路径拆分独立配置**——`LegacyBaseOpenAiService` 读的 `CAPTAIN_OPEN_AI_ENDPOINT` / `CAPTAIN_OPEN_AI_API_KEY` 指向 DashScope 即可，**该文件无需任何改动**。

### 5.1 DashScope Files API 与 `fileid://`（本轮评审实测）

PDF FAQ 生成由两个 service 承担，都继承 `Llm::LegacyBaseOpenAiService`：

| 环节 | 现状（OpenAI） | DashScope 等价物 |
|---|---|---|
| 上传 | `files.upload(purpose: 'assistants')` | `files.create(purpose: 'file-extract')` ✅ 实测可用 |
| 引用 | user message 的 content 数组里放 `{ type: 'file', file: { file_id: ... } }` | **system message 的 content 字符串放 `fileid://<id>`** |

**DashScope 有 Files API**（实测：`POST /compatible-mode/v1/files`，`purpose=file-extract` → `{"id":"file-fe-...","status":"processed"}`）。

⚠️ **但 `fileid://` 只在 `qwen-long` 上生效，其他模型静默忽略。** 实测（同一份文件、同一个提问）：

| 模型 | 结果 |
|---|---|
| `qwen-long` | ✅ 「退款会在**五个工作日内**处理」——与文件内容一致 |
| `qwen3.8-flash` / `qwen3.8-max` / `qwen-plus` | ❌ 答"取决于平台/支付渠道 1–3 个工作日"——**与完全不传 fileid 时的回答一字不差** |

**这是本设计里最危险的失败模式**：模型选错不报错，只会静默生成一堆与文档无关的 FAQ 并入库。因此 §7.5 必须配套一个**响亮失败的护栏**。

其余 `qwen-long` 能力实测：`json_object` ✅（要求 prompt 含 "json" 字样，而现有 `paginated_faq_generator` prompt 本就大量出现 JSON）、`json_schema` ❌、tool calling ❌（PDF 流程两者都不用）。

## 6. 模型选型

### 6.1 选定的模型

| 用途 | 模型 id | 说明 |
|---|---|---|
| **9 个 chat feature** | `qwen3.8-flash` | 替换 `gpt-4.1` / `gpt-4.1-mini` / `gpt-4.1-nano` / `gpt-5.2` |
| 向量检索 | `qwen3.7-text-embedding`（`dimensions: 1536`） | 替换 `text-embedding-3-small` |
| **`pdf_faq_generation`** | **`qwen-long`** | 唯一支持 `fileid://` 的模型（见 §5.1）。需改 2 个 service |
| `audio_transcription` | 不变，**功能停用** | DashScope 无 OpenAI 式 `audio.transcribe` 等价端点；该 feature 未启用 |

> `llm.yml` 共 13 个 feature：11 个 chat 类 + 1 个 embedding（`help_center_search`）+ 1 个内部（`conversation_completion`，计入 chat 类）。11 个 chat 类中 **9 个走 `qwen3.8-flash`**，`pdf_faq_generation` 单独走 `qwen-long`，`audio_transcription` 停用。
>
> `pdf_faq_generation` 不能用 `qwen3.8-flash` —— 实测 `fileid://` 在 flash/max/plus 上被**静默忽略**（§5.1）。这是全设计唯一需要第二个模型的地方。

选 `qwen3.8-flash` 覆盖 9 个 chat feature 的依据：实测它在抽取任务上与 `qwen3.8-max` 打平（长文档 13.7s/19 条 vs 14.7s/18 条，事实覆盖完全一致），且默认思考可在配置层关闭（见 §7.2）。单一模型也把 `llm.yml` 的维护面压到最小。

选 `qwen3.7-text-embedding` 而非 `text-embedding-v4` 的依据：后者**不在 `/models` 列表中**，属于旧代命名，与本次评估中遇到的三个下线模型同一模式；前者在列表中、支持 1536 维、长输入上限更宽松。两者都实测支持 `dimensions: 1536`。

### 6.2 端点：新域名 vs 旧域名

阿里云文档把 `https://dashscope.aliyuncs.com`（北京）标为**待迁移的旧域名**，推荐改用 workspace 专属域名：

```
https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1
```

| 选择 | 依据 |
|---|---|
| 本设计暂用 **`https://dashscope.aliyuncs.com/compatible-mode`** | 已用当前 key 全量实测通过；无需 WorkspaceId |
| 上线前建议改新的 workspace 域名 | 文档明说旧域名是迁移目标，且新域名"性能和稳定性更好" |

⚠️ 新域名需要从百炼控制台取 `{WorkspaceId}`，本设计无法代验。**考虑到本次评估期间已撞到三个下线模型，建议实际部署时优先用新域名**——避免又一次"用了被标记为 legacy 的东西"。这是一个实施期决策，不阻塞设计。

**`/v1` 后缀**：填写的 endpoint 不要带 `/v1` —— 四条路径都会自行补（见 §5）：前三条显式 `"#{endpoint.chomp('/')}/v1"`，`LegacyBaseOpenAiService` 由 `ruby-openai` 的 `uri()` 自动补。

## 7. 改动清单

### 7.1 模型解析链改为配置驱动

`lib/llm/feature_router.rb`：

```
现状：account override → installation override（仅 conversation_completion）→ captain_assistant_model（硬编码 gpt-5.2）→ llm.yml default
目标：account override → installation override（所有 feature）→ llm.yml default
```

| 改动 | 文件 |
|---|---|
| 删除 `installation_model_override` 中的 `return unless feature_key == 'conversation_completion'` | `lib/llm/feature_router.rb` |
| **新增 `PINNED_MODEL_FEATURES` 名单（见下，必须与上一条同时落地）** | 同上 |
| 删除 `captain_assistant_model` 方法与 `CAPTAIN_V2_ASSISTANT_MODEL` 常量 | 同上 |
| `default_model_id` 去掉对该常量的引用 | `enterprise/app/fields/captain_model_overrides_field.rb` |
| `agent_model` 分支简化为直接取 `FeatureRouter.resolve(feature: 'assistant', account: account)[:model]` | `enterprise/app/models/concerns/agentable.rb` |

**这份名单是本次的必要修复，不是可选优化。** 放开 installation override 会同时覆盖 `pdf_faq_generation`，把它从 `qwen-long` 改成 `qwen3.8-flash` —— 而 `fileid://` 在后者上**被静默忽略**，PDF 的 FAQ 会变成模型凭自身知识编造的内容并入库（§5.1）。`audio_transcription` 同样不能跟随（它已停用，但不应被悄悄改成一个无意义的模型名）。

```ruby
# 这些 feature 的模型不能跟随 installation 级的 chat 模型：
#   pdf_faq_generation   —— 必须用支持 fileid:// 的模型（qwen-long），否则静默编造，见 §5.1
#   audio_transcription  —— 已停用，但不应被改成无意义的值
PINNED_MODEL_FEATURES = %w[pdf_faq_generation audio_transcription].freeze

def installation_model_override(feature_key)
  return if PINNED_MODEL_FEATURES.include?(feature_key)
  return unless ChatwootApp.self_hosted_paid?

  InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence
end
```

保留该名单后：`pdf_faq_generation` 的模型为 `llm.yml` 的 default（**`qwen-long`**），账号级 override 仍可用（白名单内）。

保留 `installation_model_override` 中的 `ChatwootApp.self_hosted_paid?` 门槛，避免把 instance-specific 行为硬编码进 OSS 路径。

⚠️ **依赖前提**：该门槛要求 `self_hosted_paid?` 为真，否则 installation override 不生效、会静默回落到 `llm.yml` 的 `default`。本实例的 `INSTALLATION_PRICING_PLAN=enterprise`，满足该条件；若某天该配置被订阅检查打回（见 `deploy/upstream-comparison/README.md`），`CAPTAIN_OPEN_AI_MODEL` 会失效而功能仍"看起来正常"——这是需要写进运行手册的隐性耦合。

**效果**：`CAPTAIN_OPEN_AI_MODEL` 从"只管 1 个 feature"变成"控制全部 11 个的默认"，且不走白名单校验（`installation_model_override` 本就没有 `valid_model_for?` 检查）。

### 7.2 `config/llm.yml` 支持 per-model 参数

model 条目新增可选 `params:`：

```yaml
models:
  qwen3.8-flash:
    provider: openai
    display_name: 'Qwen3.8 Flash'
    credit_multiplier: 1
    params:
      enable_thinking: false
  qwen3.7-text-embedding:
    provider: openai
    display_name: 'Qwen3.7 Text Embedding'
    credit_multiplier: 1
    params:
      dimensions: 1536
  gpt-4.1:
    provider: openai
    display_name: 'GPT-4.1'
    credit_multiplier: 3
```

`Llm::Models` 新增 `model_params(model)`。

**为什么必须按模型声明而不是无条件传**：`enable_thinking` 对 OpenAI 是未知参数，会 400。provider 差异必须由配置表达。

同时 `models:` 段与各 feature 的 `models:` 白名单**同时保留两套 provider 的 id**，使切回 OpenAI 不需要改文件。

### 7.3 代码读取并应用参数

| 位置 | 改动 |
|---|---|
| `lib/captain/base_task_service.rb#build_chat` | `chat.with_params(**Llm::Models.model_params(model))` |
| `enterprise/app/models/concerns/agentable.rb#agent` | `Agents::Agent.new(..., params: Llm::Models.model_params(model))` |
| `enterprise/app/services/captain/llm/embedding_service.rb#get_embedding` | `RubyLLM.embed(content, model: model, **Llm::Models.model_params(model))` |

（RubyLLM 的 `embed` 原生支持 `dimensions:` 关键字参数。）

⚠️ **空 hash 要短路**：在 §11 的第 ① 段（endpoint 仍是 OpenAI）里，`model_params('gpt-4.1')` 返回 `{}`。`chat.with_params(**{})` 等价于 `chat.with_params()` —— 是否接受无参调用未经验证。写成：

```ruby
params = Llm::Models.model_params(model)
chat.with_params(**params) if params.any?
```

`Agents::Agent.new(..., params: {})` 与 `RubyLLM.embed(..., **{})` 同理，用 `if params.any?` 或直接传空 hash（后者需实测）。

### 7.4 `openai_use_system_role = true`

`lib/llm/config.rb#configure_ruby_llm` 增加一行。对 OpenAI 无害（`system` 是合法 role），对 DashScope 必需。全局设置，无需按 provider 分支。

### 7.5 PDF 两个 service 的改造

`LegacyBaseOpenAiService` **本身不需要改**（endpoint 由 §5 的机制自动指向 DashScope）。要改的是它的两个子类：

| 文件 | 改动 |
|---|---|
| `enterprise/app/services/captain/llm/pdf_processing_service.rb` | 上传 `purpose: 'assistants'` → `'file-extract'` |
| `enterprise/app/services/captain/llm/paginated_faq_generator_service.rb` | 引用方式改为 `fileid://`；新增模型护栏（见下） |

**引用方式的改造**：

```ruby
# 现状：user message 的 content 数组里放 file 部件
def build_user_content(start_page, end_page)
  [
    { type: 'file', file: { file_id: @document.openai_file_id } },
    { type: 'text', text: page_chunk_prompt(start_page, end_page) }
  ]
end

# 改为：system message 的 content 字符串里放 fileid://
def build_chunk_parameters(start_page, end_page)
  {
    model: @model,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: "fileid://#{@document.openai_file_id}" },
      { role: 'user', content: page_chunk_prompt(start_page, end_page) }
    ]
  }
end
```

⚠️ **隐性耦合**：`json_object` 要求 prompt 里出现 "json" 字样，否则 400。现有 `SystemPromptsService.paginated_faq_generator` 大量出现 JSON / ```json，满足条件——但改动该 prompt 时须注意保留这一点。

**模型护栏（必须做，见 §5.1 的静默失败）**：

```ruby
# fileid:// 在不支持它的模型上会被静默忽略——模型改用自身知识编 FAQ 且不报错。
# 宁可响亮失败，也不能把编造的 FAQ 写进知识库。
FILE_REFERENCE_MODELS = %w[qwen-long].freeze

def initialize(document, options = {})
  # ... 原有赋值 ...
  @model = Llm::FeatureRouter.resolve(feature: 'pdf_faq_generation', account: document.account)[:model]
  return if FILE_REFERENCE_MODELS.include?(@model)

  raise CustomExceptions::Pdf::FaqGenerationError,
        "pdf_faq_generation 必须使用支持 fileid:// 的模型，当前为 #{@model}——该模型会静默忽略文件内容"
end
```

**顺带清理**：改成 `build_chunk_parameters` 后，原来的 `build_user_content` 不再被调用，应删除（CLAUDE.md：移除死代码）。

**字段名不清不楚但本次不改**：`document.openai_file_id` / `store_openai_file_id` 切换后存的是 DashScope file id。改列名要迁移 + 触及多个调用点，属独立清理工作；本次只在代码处加注释说明。

### 7.6 `config/llm_models.json` 注册新模型

新增 **`qwen3.8-flash`、`qwen3.7-text-embedding`、`qwen-long`** 三条。**不可省略**——`Llm::Models.temperature_for` 会调用 `RubyLLM.models.find(model).metadata[:temperature]`，未注册会抛 `RubyLLM::ModelNotFoundError`（与上游 issue #16114 同一成因），且 assistant 路径每次构造 agent 都会走到。

### 7.7 配置与注册表挂载为 volume

`config/llm.yml` 与 `config/llm_models.json` 都是启动时加载的常量。要让"新增模型 id 也不用重建"，须使其在容器外可编辑：

```yaml
# deploy/upstream-comparison/docker-compose.yml
volumes:
  - <宿主机路径>/llm.yml:/app/config/llm.yml:ro
  - <宿主机路径>/llm_models.json:/app/config/llm_models.json:ro
```

⚠️ **`<宿主机路径>` 待定**：compose 只把工作树当作**构建上下文**交给服务器 daemon（构建完即丢弃），运行期容器里的 `/app/config/*` 来自镜像。因此挂载源必须是服务器上一个**持久存在的路径**——需要按 `deploy/upstream-comparison/` 的实际布局确定（是随 compose 文件旁放一份，还是别的位置），不能想当然写相对路径。

⚠️ **动 compose 前必须先读 `deploy/upstream-comparison/README.md`**（含订阅检查屏蔽、`sudo docker compose` 等注意事项）。

**风险与缓解**：挂载后容器内这两个文件与镜像版本脱钩。上游若改动 `llm.yml` 结构，宿主机那份会过期并导致启动失败。缓解方式：在 README 中登记这两个文件为"需跟随上游手动同步的运维资产"。

### 7.8 汇总

| 类别 | 数量 | 明细 |
|---|---|---|
| Ruby 文件 | **8 个** | `lib/llm/feature_router.rb`、`app/fields/captain_model_overrides_field.rb`(EE)、`app/models/concerns/agentable.rb`(EE)、`lib/captain/base_task_service.rb`、`app/services/captain/llm/embedding_service.rb`(EE)、`lib/llm/config.rb`、`app/services/captain/llm/pdf_processing_service.rb`(EE)、`app/services/captain/llm/paginated_faq_generator_service.rb`(EE) |
| 配置 / 数据文件 | 2 个 | `config/llm.yml`、`config/llm_models.json` |
| InstallationConfig | **4 改，0 增** | 值见 §6.1 / §6.2；操作见 §13 |
| 部署 | 1 处 | compose volume（§7.7） |

注：
- `agentable.rb` 在 §7.1 与 §7.3 各有一处改动。
- **`app/services/llm/legacy_base_open_ai_service.rb` 不在列表里** —— 它读的 endpoint/key 现在指向 DashScope 即可，不需要改（§5）。
- InstallationConfig 无需新增 —— PDF 迁移后不再需要单独的 OpenAI 配置线，这是选路 B 带来的简化。

## 8. 向量迁移

### 8.1 零内容损失

三张表存的都是 embedding 向量，而对**已有内容**计算：

| 表 | 嵌入的内容 | 索引名 |
|---|---|---|
| `captain_assistant_responses` | `"#{question}: #{answer}"` | `vector_idx_knowledge_entries_embedding` |
| `captain_faq_suggestions` | `"#{question}: #{answer}"` | `vector_idx_captain_faq_suggestions_embedding` |
| `article_embeddings` | `term` | `index_article_embeddings_on_embedding` |

三者都有回调在 `saved_change_to_*? || embedding.nil?` 时入队 `Captain::Llm::UpdateEmbeddingJob`。因此**不需要删除数据、不需要重新生成 FAQ，人工编辑过的条目也保留**——只需重算向量。

### 8.2 重算

```ruby
Captain::AssistantResponse.find_each { |r| Captain::Llm::UpdateEmbeddingJob.perform_now(r, "#{r.question}: #{r.answer}") }
Captain::FaqSuggestion.find_each     { |s| Captain::Llm::UpdateEmbeddingJob.perform_now(s, "#{s.question}: #{s.answer}") }
ArticleEmbedding.find_each           { |a| Captain::Llm::UpdateEmbeddingJob.perform_now(a, a.term) }
```

串行执行，避免一次性打爆 DashScope 限流。

### 8.3 重建索引

换 embedding 模型后整个向量分布改变，ivfflat 索引若不重建，召回会明显下降：

```sql
REINDEX INDEX vector_idx_knowledge_entries_embedding;
REINDEX INDEX vector_idx_captain_faq_suggestions_embedding;
REINDEX INDEX index_article_embeddings_on_embedding;
```

### 8.4 迁移窗口

新旧向量共用一个 ivfflat 索引，混在一起时距离度量无意义，检索结果是垃圾。

| 环境 | 策略 |
|---|---|
| `:81` | 不停机，接受窗口内检索降级 |
| 生产 | **停机迁移**：停 Captain 相关 worker → 重算 → REINDEX → 恢复 |

### 8.5 PDF 文件重新上传

`document.openai_file_id` 存的是 **OpenAI 侧的文件 id**（`file-...`），DashScope 无法解析。切到 DashScope 后这些 id 全部失效。

`PdfProcessingService#process` 有一句 `return if document.openai_file_id.present?` —— 所以**光是切换 endpoint 不会触发重新上传**，它只会拿到一个失效的 id 去请求。

```ruby
# 清空后让 crawl_job 重新走上传（或手动逐条触发 PdfProcessingService）
Captain::Document.where.not(openai_file_id: nil).update_all(openai_file_id: nil)
```

⚠️ **注意**：清空后到重新上传完成之间，这些文档的 PDF FAQ 生成会因 `openai_file_id.blank?` 抛 `CustomExceptions::Pdf::FaqGenerationError`（响亮失败，符合预期）。

**规模待查** —— 原本安排了一次查询统计 `captain_documents` 中 `openai_file_id` 非空的行数，该查询超时失败，未取到数字。实施前需补测，以决定是逐条重传还是批量重跑。

## 9. 回滚

| 层次 | 手段 |
|---|---|
| 代码/配置 | `deploy/upstream-comparison/deploy.sh --tag <上一个 tag>` |
| InstallationConfig | Super Admin 改回原值 |
| **向量** | ⚠️ **回滚不了**——重算后要回 OpenAI 需再重算一遍 |
| **PDF 文件 id** | ⚠️ 同样回不去——旧的 OpenAI `file-...` id 已被清空（§8.5），回滚后要重新上传 |

**对策**：
- 迁移前 `pg_dump` 三张表的 `id, embedding` 两列 —— 回滚时恢复备份，避免二次全量重算
- **同时备份 `captain_documents` 的 `id, openai_file_id`** —— 这样回滚时能直接还原旧的 OpenAI file id，不必重传 PDF

## 10. 验证清单

在 `:81` 上逐条跑通：

1. Playground 能回话（覆盖 agents SDK 路径；响应应 <10s，若 >15s 说明 `enable_thinking: false` 未生效）
2. FAQ 生成能出条（`json_schema` 路径）
3. `faq_lookup` 能查到相关条目（embedding 路径 + REINDEX 生效）
4. **上传 PDF 生成 FAQ** —— **最关键回归点**，要同时验证三件事：
   - `purpose: 'file-extract'` 上传成功，拿到 `file-fe-...` 形态的 id
   - `fileid://` 引用**真的生效** —— 生成的 FAQ 必须能在 PDF 原文里找到依据。**这是防"静默编造"的唯一手段**：随便抽 3 条 FAQ，回原文核对
   - `PINNED_MODEL_FEATURES` 生效：`pdf_faq_generation` 的模型是 `qwen-long`，未被 `CAPTAIN_OPEN_AI_MODEL` 覆盖成 `qwen3.8-flash`（护栏应会响亮报错，不会静默）
5. Super Admin → Accounts → Captain models 页面能打开（验证 `llm.yml` 改动未破坏 `feature_config`）
6. 编辑器 AI 改写可用
7. 日志中无：`developer is not one of` / `ModelNotFoundError` / `This response_format type is unavailable`
8. **延迟实测（必做，不只是通过/失败）** —— 量一次 Captain Playground 调用的真实墙钟：

   | 观察值 | 含义 | 处理 |
   |---|---|---|
   | 每次调用额外 **~260ms** | 连接被复用，只付 1 个 RTT | 正常，符合预期 |
   | 每次调用额外 **~800ms** | 每次新建 TLS 连接 | **需处理连接复用**（换 persistent adapter）。否则相对 OpenAI 每调用回归 ~580ms |

   背景见附录 B：`api.openai.com` 在悉尼有 Cloudflare 本地 PoP（TLS 握手 2ms），DashScope 没有（握手付完整 255ms）。

## 11. 部署：三段式

| 段 | 内容 | 验证点 |
|---|---|---|
| ① 打底座 | 代码：§7.1、§7.3、§7.4、§7.6。配置：§7.2 的**新增部分**（把 qwen 条目加进 `models:` 与各 feature 白名单，**不改任何 `default:`**）。**endpoint 仍指 OpenAI** | **功能应完全不变**——干净的"没改坏"基线 |
| ② 切换 | §7.5（PDF 两个 service）+ §7.2 的 `default:` 改写 + InstallationConfig 4 项 + §8 向量重算 + REINDEX + §8.5 PDF 重传 | §10 全部 8 条 |
| ③ 推生产 | 同一 commit tag + 停机迁移 | 同 §10 |

⚠️ **§7.5 的 PDF 改动不能放进第 ① 段。** 它写的是 DashScope 专有的 `fileid://` 与 `purpose: 'file-extract'`；endpoint 还指 OpenAI 时落地，PDF 生成会立刻坏掉 —— 第 ① 段"功能完全不变"就不成立了。

同理，**§7.2 不能在第 ① 段改 `default:`**：那样 feature 的默认模型指向 qwen，而 endpoint 还是 OpenAI → 404。

第 ① 段的价值在于把失败点分离：它验证的是 §7.1 / §7.3 / §7.4 这几个"解析链与参数透传"改动**在旧 provider 上无副作用**，与 DashScope 自身的行为差异分开看。

## 12. 风险与未决项

| 项 | 说明 |
|---|---|
| **embedding 检索质量无基线** | 验收标准为"功能跑通"，未测 Qwen 与 `text-embedding-3-small` 的召回差异。若后续质疑检索质量下降，需补做对比实验。当前已知：DashScope 三个候选之间打平（top-1 4/6、top-3 6/6） |
| **`enable_thinking` 对 OpenAI 会 400** | 因此必须走 §7.2 的按模型 `params:`，不能在代码里无条件传 |
| **embedding 路径需进程重启** | `Llm::Config.reset!` 已定义但全仓库无调用点，`initialize!` 又是 `@initialized` 记忆化的。chat 路径每次现读 InstallationConfig 故立即生效；embedding 走全局 config，必须重启。故准确表述是"零重建"，非"零重启" |
| **volume 挂载导致配置与镜像脱钩** | 见 §7.7 缓解措施 |
| **`:81` 与生产是两台机器** | 生产迁移窗口需单独安排；本设计不包含生产的停机通知与执行时序 |
| **`qwen3.8-flash` 自身也会下线** | 这正是 §7 存在的理由：届时只需改 `CAPTAIN_OPEN_AI_MODEL` + 注册新 id，不用重建 |
| **`PINNED_MODEL_FEATURES` 是会腐烂的硬编码名单** | 上游若新增需要固定模型的 feature，名单不更新就会重复本次的静默编造。缓解：名单旁注释指向本文档 §5.1；每次跟进上游 `llm.yml` 变更时对照检查 |
| **`fileid://` 的静默忽略是本设计最大隐患** | 已用 §7.5 的护栏挡住"换错模型"，但护栏只校验模型名。若 Alibaba 未来改了 `qwen-long` 的行为，护栏不会发现。缓解：§10 第 4 条要求人工抽 3 条 FAQ 回原文核对 |
| **PDF 路径破坏了 provider 可移植性** | §7 的"切 provider 零重建"对 9 个 chat feature + embedding 成立，但 **PDF 不行**：`fileid://` 是 DashScope 专有，切回 OpenAI 要改回 `file: { file_id: }` 的代码。这是选路 B 的已知代价 |
| **音频转写停用** | endpoint 切到 DashScope 后 `SpeechToTextService` 会拿到 `gpt-4o-mini-transcribe` 打向不存在的 `/audio/transcriptions`。该 feature 未启用故无影响，但 llm.yml 里 `audio_transcription` 的条目成为死配置。若要启用需另找方案 |
| **延迟可能回归（取决于连接复用）** | 见 §10 第 8 条与附录 B。`api.openai.com` 有悉尼本地 PoP，DashScope 没有；若每次调用新建 TLS 连接，切过去每调用多 ~580ms |
| **PDF 换到 `qwen-long` 后的成本未核算** | 它从 `gpt-4.1-mini`（$0.40/$1.60）换成 `qwen-long`，而 `qwen-long` 的单价未采集（阿里云对 qwen-long 的计价与 flash 不同档）。附录 C 的降本估算只覆盖 chat feature，未含 PDF |
| **成本收益需按 feature 核对** | §8 与附录 C 的估算基于单价倍数，不是实际用量。token 数据在 Langfuse（数据库只有响应计数）。要出准数需从 Langfuse 按 feature 导出 |

## 13. 日常运维操作表

设计落地后，"换模型/换 provider"分四档。**判据是"改完之后要不要重建镜像"**。

| # | 操作 | 要做的事 | 重建镜像 | 重算向量 |
|---|---|---|---|---|
| 1 | 换 chat 模型（同 provider，id **已注册**） | 改 `CAPTAIN_OPEN_AI_MODEL` → `docker compose restart rails sidekiq` | ❌ | ❌ |
| 2 | 换 chat 模型（**新 id**） | 编辑宿主机 `llm.yml` + `llm_models.json`（volume 挂载）→ 同第 1 档 | ❌ | ❌ |
| 3 | **切 provider**（chat + embedding） | 改 `CAPTAIN_OPEN_AI_ENDPOINT` / `CAPTAIN_OPEN_AI_MODEL` / `CAPTAIN_EMBEDDING_MODEL` → restart | ❌ | ✅ **必须** |
| 4 | 改 `PINNED_MODEL_FEATURES` 里的 feature 模型，或改 PDF 的 provider | **改代码**（PDF 还需清空 `openai_file_id` 并重传，§8.5） | ✅（40 分钟） | 视情况 |

> 「重启」的确切命令以 `deploy/upstream-comparison/README.md` 为准（该主机上 `docker compose` 需要 `sudo`，且 compose 文件在 `deploy/upstream-comparison/` 下）。

**为什么第 3 档必须重启**：`Llm::Config.reset!` 全仓库无调用点，`initialize!` 又是 `@initialized` 记忆化的。chat 路径每次现读 InstallationConfig 故立即生效，**但 embedding 走全局 config，必须重启进程**。

**为什么第 3 档必须重算向量**：换 embedding 模型就是换向量空间，三张表都要重算 + REINDEX（§8）。**只换 chat 模型（第 1、2 档）不受影响。**

**第 2 档的前提是 §7.7 的 volume 挂载**。不挂的话，编辑 `llm.yml` 得改仓库 → 重建，就退化成第 4 档了。

### 13.1 第 3 档的完整步骤（切 provider）

```bash
# 1. Super Admin → App Configs → Captain，改 3 项：
#    CAPTAIN_OPEN_AI_ENDPOINT      例 https://dashscope.aliyuncs.com/compatible-mode（不带 /v1）
#    CAPTAIN_OPEN_AI_MODEL         例 qwen3.8-flash
#    CAPTAIN_EMBEDDING_MODEL       例 qwen3.7-text-embedding
# 2. 先备份（回滚用，见 §9）
#    pg_dump ... -t captain_assistant_responses -t captain_faq_suggestions -t article_embeddings
#    pg_dump ... -t captain_documents
# 3. 停 Captain 相关 worker（生产环境；:81 可跳过）
# 4. 重算向量（§8.2）→ REINDEX（§8.3）
# 5. 重传 PDF（§8.5）
# 6. 重启进程（刷新 embedding 的全局 config）
#    docker compose restart rails sidekiq
# 7. 跑 §10 的 8 条验证
# 8. 恢复 worker
```

### 13.2 明确不在本设计范围内的

| 事项 | 为什么 |
|---|---|
| `pdf_faq_generation` 跟随 provider 切换 | `fileid://` 是 DashScope 专有。要支持双向，需把引用方式也做成配置（~5 行），本设计按 YAGNI 不做 |
| 用 `assume_model_exists` 免掉 `llm_models.json` 注册 | 要改 3 处调用点，收益只是省两行配置 |
| 把 `llm.yml` / `llm_models.json` 搬进数据库 | 大重构，风险与收益不匹配 |
| 恢复音频转写 | DashScope 无 OpenAI 式 `audio.transcribe`；该 feature 未启用 |
| 重命名 `document.openai_file_id` | 需迁移 + 触及多个调用点，属独立清理 |

## 附录 A：DashScope 实测能力矩阵

（2026-10-09，中国大陆区 key，端点 `dashscope.aliyuncs.com/compatible-mode/v1`，`/models` 返回 262 个模型）

### A.1 通性

| 能力 | 结论 |
|---|---|
| `role: developer` | ❌ qwen / deepseek / glm / kimi **全系拒绝** |
| tool calling | ✅ 所有测过的模型通过 |

### A.2 严格 `json_schema`

| 档位 | 模型 |
|---|---|
| ✅ 通过 | `qwen3.8-max` `qwen3.7-max` `qwen3-max` `qwen-plus` `qwen-flash` `qwen3.8-flash` `qwen3.7-flash` `qwen3.8-2.4t-a95b` `kimi-k3` `deepseek-v3.2` `deepseek-v4-pro` `deepseek-v4-flash` |
| ⚠️ 静默降级为 `json_object` | `qwen3.6-plus` `qwen3.5-plus` `qwen3.6-flash` `qwen3.5-flash`（不报 schema 错，改为要求 prompt 含 "json"，否则 400） |
| ❌ 不遵守 | `glm-5.3`（截断）、`qwen3.8-27b`（schema 要求 object 却返回数组） |
| ❌ 硬 400 | `deepseek-v4.1-flash`（`This response_format type is unavailable now`） |

### A.3 抽取任务对比（同一份 6 事实文本，检查 `q` 字段是否为真问句）

| 模型 | 耗时 | tok | FAQ 条数 | 问句质量 |
|---|---|---|---|---|
| `deepseek-v4-pro` +off | 4.9s | 271 | 8 | ✅ |
| `deepseek-v3.2`（天生非推理） | 4.6s | 210 | 7 | ✅ |
| `deepseek-v4-flash` +off | 2.4s | 233 | 6 | ✅ |
| `qwen3.8-max` +off | 6.9s | 332 | 8 | ✅ |
| `qwen3-max`（默认非推理） | 3.7s | 247 | 6 | ✅ |
| `qwen-plus`（默认非推理） | 6.1s | 252 | 6 | ✅ |
| `qwen-flash` | 1.9s | 242 | 6 | ❌ 照抄原文字句 |
| `qwen-turbo` | 2.1s | 238 | 6 | ❌ 照抄原文字句 |

⚠️ **教训：只看条数会骗人。** `qwen-flash` 条数不差但任务未做对。条数差异（6 vs 8）多为合并/拆分粒度不同，不一定是漏抽。

### A.4 长文档压测（约 600 字、19 个可核对事实点）

| | `qwen3.8-flash` +off | `qwen3.8-max` +off |
|---|---|---|
| 耗时 | 13.7s | 14.7s |
| 输出 tok | 901 | 898 |
| FAQ 条数 | 19 | 18 |
| 事实覆盖 | 全覆盖 | 全覆盖 |

### A.5 thinking 的代价

`enable_thinking: false` 对 Qwen3.x 全系有效：

| 模型 | 默认 | `enable_thinking: false` |
|---|---|---|
| `qwen3.8-flash` | 18.2s / 1088 tok / 思考 3407 字符 | 4.7s / 327 tok / 0 |
| `qwen3.8-max` | 18.0s / 760 tok / 思考 2089 字符 | 6.9s / 332 tok / 0 |
| `qwen3.7-max` | 17.4s / 1747 tok / 思考 5431 字符 | 5.0s / 329 tok / 0 |
| `deepseek-v4-pro` | 17.7s / 814 tok / 思考 2336 字符 | 5.7s / 288 tok / 0 |

**FAQ 条数不变** —— 对抽取类任务，思考是纯开销：慢 2.6–3.7 倍、贵最多 5.3 倍。

上游的对应判断一致：11 个 feature 中只有 `conversation_faq_generation` 与 `help_center_article_generation` 默认用推理模型（`gpt-5.2`），其余 9 类均为非推理。

### A.6 embedding 维度与限制

| 模型 | 默认维度 | `=1536` | 长输入 | 批量上限 | 在 `/models` |
|---|---|---|---|---|---|
| **`qwen3.7-text-embedding`** | 1024 | ✅ 1536 | ✅ 8000+ 字符 | ≥12 | ✅ |
| `qwen3.7-text-embedding-flash` | 1024 | ❌ **静默返回 1024** | — | — | ✅ |
| `text-embedding-v4` | 1024 | ✅ 1536 | — | 10 | ❌ |
| `text-embedding-v3` | 1024 | ❌ 400 | — | — | ❌ |
| `text-embedding-v2` | 1536（固定） | 1536 | ⚠️ 仅 2048 字符 | — | ❌ |

⚠️ **`-flash` 变体会静默忽略 `dimensions: 1536` 并返回 1024 维**——比报错更危险，切勿使用。

### A.7 检索质量（12 条语料 / 6 个换词查询）

`qwen3.7-text-embedding`、`qwen3.7-text-embedding-flash`、`text-embedding-v4` 三者排名完全一致：top-1 **4/6**、top-3 **6/6**。

### A.8 Files API 与 `fileid://`（PDF 路径）

上传（`POST /compatible-mode/v1/files`，`purpose=file-extract`）实测通过，返回 `{"id":"file-fe-...","status":"processed"}`。

**引用方式**：`{'role':'system','content':'fileid://<id>'}`。

**关键实测 —— 只有 `qwen-long` 真的读取文件，其余模型静默忽略**（同一份文件、同一提问）：

| 模型 | 回答 |
|---|---|
| `qwen-long` | 「退款会在**五个工作日内**处理」← 与文件一致 ✅ |
| `qwen3.8-flash` | 「取决于平台/支付渠道，1–3 个工作日」← **与不传 fileid 时一字不差** ❌ |
| `qwen3.8-max` | 同上 ❌ |
| `qwen-plus` | 同上 ❌ |

`qwen-long` 其余能力：`json_object` ✅（要求 prompt 含 "json"）、`json_schema` ❌、tool calling ❌、`developer` role ❌。

分页指令实测可用（`fileid://` + `json_object` + "只处理第 1 页" → 返回结构正确的 JSON）。

## 附录 B：区域与延迟（`:81` 服务器实测）

`32.236.75.213` = **AWS EC2 Sydney（`ap-southeast-2`）**，反查 `ec2-32-236-75-213.ap-southeast-2.compute.amazonaws.com`，AS16509。

从该机器实测（`curl` 计时，连接复用指同一进程内连续请求）：

| 端点 | TCP 握手 ×5 | 复用后单请求 | 备注 |
|---|---|---|---|
| `api.openai.com` | **2–3ms** | 218 / 262ms | Cloudflare 悉尼本地 PoP，握手在本地终结 |
| `dashscope-intl.aliyuncs.com`（新加坡 ap-southeast-1） | 254 / 255 / 256 / 255 / 255ms | **263 / 264ms** | 稳定，方差 ±0.5ms |
| `dashscope.aliyuncs.com`（中国，走 IPv6） | 235 / **735** / 240 / 229 / 281ms | 281 / 280ms | 抖动大，出现过 735ms |

`dashscope-intl` 解析到 `nlb-….ap-southeast-1.nlb.aliyuncs.com`（47.236.x / 47.245.x，阿里云新加坡 NLB）。

**结论**：
1. 三个端点从悉尼的**单次请求开销都在 220–280ms**，迁移在延迟上接近中性。这段延迟是地理距离，不是厂商差异。
2. **推荐新加坡区域** —— 不是快（263 vs 281ms），而是**稳定**（±0.5ms vs 有过 735ms 抖动）。中国路径需过边界，尾延迟不可控。
3. ⚠️ **当前 key 是中国大陆区的**，`dashscope-intl` 返回 401。用新加坡端点需开**阿里云国际站**账号 + 新 key（两站账号体系独立）。
4. **真正的延迟杠杆是共址**，不是选区域：AWS 新加坡 → DashScope 新加坡约 1–5ms，每轮对话可省 250–750ms（Captain 一轮回复 1–3 次 LLM 调用）。但机房位置应主要跟随**客户**分布，不能只看模型延迟 —— 这是产品取舍。
5. ⚠️ **风险**：OpenAI 有悉尼本地 PoP（握手 2ms），DashScope 没有（握手付完整 255ms）。连接复用下两者都是 ~1 RTT；**若每次调用新建连接，DashScope 会变成 ~800ms/调用**。见 §10 第 8 条。

## 附录 C：成本对比

汇率按 1 USD ≈ 7.2 CNY。

`qwen3.8-flash`：输入 ¥0.8/M ≈ **$0.111/M**，输出 ¥2.7/M ≈ **$0.375/M**，缓存输入 ¥0.1/M ≈ **$0.0139/M**。
最大输入 991K（思考模式 983K），最大输出 128K。

OpenAI（取自 `config/llm_models.json`）：

| 模型 | 输入 $/M | 缓存读 $/M | 输出 $/M |
|---|---|---|---|
| gpt-4.1 | 2.00 | 0.50 | 8.00 |
| gpt-4.1-mini | 0.40 | 0.10 | 1.60 |
| gpt-4.1-nano | 0.10 | 0.03 | 0.40 |
| gpt-5.2 | 1.75 | 0.175 | 14.00 |

倍数（qwen3.8-flash 相对便宜）：

| vs | 输入 | 输出 |
|---|---|---|
| gpt-4.1 | 18× | 21× |
| gpt-4.1-mini | 3.6× | 4.3× |
| gpt-5.2 | 15.8× | **37×** |
| gpt-4.1-nano | **反而贵 11%** | 持平 |

**节省幅度取决于用量分布**：省钱主力是 `assistant` 从 gpt-5.2 降到 flash（它是唯一每条客户消息都触发的 feature）。若 assistant 占 token 大头，整体降幅接近 30×；若主要成本在 mini 档的批量任务，降幅约 4×。

**注意**：DashScope 的 Batch 价（输入 ¥0.4 / 输出 ¥1.35）要求走批量推理接口，Chatwoot 不走 Batch API，不可按此预估。

**准数需从 Langfuse 取**（token 用量不在数据库中；`increment_response_usage` 只计数不记 token）。

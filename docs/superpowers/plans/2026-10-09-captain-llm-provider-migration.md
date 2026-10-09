# Captain LLM Provider 迁移（OpenAI → DashScope）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Captain 的 chat 与 embedding 从 OpenAI 迁到阿里云 DashScope，并把"以后换 provider / 换模型"从"改代码 + 重建镜像"降级为"改配置 + 重启"。

**Architecture:** 单条配置线 —— `CAPTAIN_OPEN_AI_ENDPOINT` 一个值同时服务 RubyLLM、Agents SDK 与 ruby-openai SDK 三条路径（后者的 `/v1` 由 SDK 自动补）。模型解析链改为"账号 override → installation override（覆盖全部 feature）→ `llm.yml` default"，provider 差异（`enable_thinking`、embedding 维度）由 `llm.yml` 的 per-model `params:` 表达。PDF FAQ 生成单独走 `qwen-long` + DashScope Files API 的 `fileid://`。

**Tech Stack:** Ruby 3.4.4 / Rails、`ruby_llm` 2.0.0、`ruby-openai` 7.3.1、`agents` gem、PostgreSQL + pgvector、Docker（自建镜像）

**Spec:** `docs/superpowers/specs/2026-10-09-captain-llm-provider-migration-design.md`

## Global Constraints

- **分支**：`feat/captain-llm-provider-migration`，worktree 位于 `.claude/worktrees/captain-llm-migration`
- **行长度**：150 字符（`.rubocop.yml` 的 `Layout/LineLength`）
- **提交信息**：Conventional Commits（`type(scope): subject`）；**不要在提交信息里提 Claude**（CLAUDE.md）
- **本机没有 Ruby 工具链**：`.ruby-version` 要 3.4.4，本机是系统 ruby 4.0.6，无 rbenv，无 `vendor/bundle`。
  → `bundle exec rspec` **在本机跑不了**。本机能做的验证只有三种，见下。
- **CLAUDE.md 的硬性要求**：移除死代码；不要为推测性场景加分支；尽早在共享入口处校验

### 关于文中的 `<compose>` / `<app目录>` 占位符

Task 8 与 Task 9 的 shell 命令里有 `<compose>` 与 `<app目录>`。**这不是漏写** —— 服务器上 compose 文件的实际路径必须现场确认（Task 8 Step 1 读 `deploy/upstream-comparison/README.md`，Step 2 上服务器看目录布局）。CLAUDE.md 明确要求动 compose 前先读那份 README。

执行 Task 9 前，先把这两个值确定下来并写进 runbook，之后所有命令都用实测值替换。

## 本机可用的验证手段（每个任务都从这三种里选）

```bash
# ① 语法检查（任何 ruby 都行）
ruby -c <file>

# ② rubocop（已装到 /tmp，用项目自己的 .rubocop.yml）
export GEM_HOME=/tmp/rubocop-gems GEM_PATH=/tmp/rubocop-gems PATH=/tmp/rubocop-gems/bin:$PATH
rubocop --no-server --force-exclusion -a <file>

# ③ 无 Rails 的纯逻辑 harness（只适用于不依赖 Rails 常量的逻辑）
ruby -I. /tmp/<harness>.rb
```

**rspec 必须在一个有工具链的机器（或 CI）上跑**，命令：

```bash
bundle exec rspec spec/lib/llm/models_spec.rb spec/lib/llm/feature_router_spec.rb
```

计划里每个任务都写明了哪一步能在本机验证、哪一步必须等工具链。**不要把"本机 rubocop 通过"当成功能正确。**

## 阶段划分（对应 spec §11）

| 阶段 | 内容 | 验证点 |
|---|---|---|
| ① 打底座 | Task 1–5。endpoint **仍指 OpenAI** | 功能完全不变 |
| ② 切换 | Task 6–9。PDF 代码 + default 改写 + 配置 + 迁移 | spec §10 的 8 条 |
| ③ 推生产 | Task 10 | 同 spec §10 |

⚠️ **与 spec §11 的一处有意偏差**：spec 把 §7.1 整块放进阶段①，但 §7.1 里"删除 `CAPTAIN_V2_ASSISTANT_MODEL`"会让 captain 账号的 assistant 模型从硬编码的 `gpt-5.2` 变成 `llm.yml` 的 `gpt-4.1` —— **这是行为变化**，会破坏阶段①"功能完全不变"的验证意义。因此本计划把它拆到阶段②（Task 6）。

---

## Task 1: `Llm::Models` 支持 per-model 参数

**Files:**
- Modify: `lib/llm/models.rb`
- Test: `spec/lib/llm/models_spec.rb`

**Interfaces:**
- Consumes: 无
- Produces:
  - `Llm::Models.model_params(model_name) -> Hash` —— **键为 Symbol**（`{enable_thinking: false}`），无配置时返回 `{}`
  - ⚠️ **键必须是 Symbol**：调用方把它 splat 给 `RubyLLM.embed`（`dimensions:` 是真关键字参数）和 `chat.with_provider_options`。String 键会静默取不到 → `dimensions` 不生效 → 写入 `vector(1536)` 失败。这是 pre-flight 扫描裁定的（见 ledger）。

- [ ] **Step 1: 写失败的测试**

追加到 `spec/lib/llm/models_spec.rb` 的最后一个 `end` 之前（与该文件其余 `describe` 同级）：

```ruby
  describe '.model_params' do
    it 'returns an empty hash for a model without params' do
      expect(described_class.model_params('gpt-4.1')).to eq({})
    end

    it 'returns an empty hash for an unknown model' do
      expect(described_class.model_params('no-such-model')).to eq({})
    end

    it 'returns the configured params with symbol keys' do
      expect(described_class.model_params('qwen3.8-flash')).to eq(enable_thinking: false)
    end

    it 'returns embedding params with symbol keys' do
      expect(described_class.model_params('qwen3.7-text-embedding')).to eq(dimensions: 1536)
    end
  end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bundle exec rspec spec/lib/llm/models_spec.rb -e 'model_params'`
Expected: FAIL —— `undefined method 'model_params' for Llm::Models`

（本机跑不了 rspec。可以先只做 Step 3，把 rspec 留到有工具链时跑。）

- [ ] **Step 3: 实现**

在 `lib/llm/models.rb` 的 `model_config` 之后插入：

```ruby
    # Keys must be symbols: callers splat these into RubyLLM, which reads them by symbol.
    def model_params(model_name)
      model_config(model_name)&.dig('params')&.symbolize_keys || {}
    end
```

**不要**改 `feature_config` —— 把 params 暴露给前端没有消费方（YAGNI），且会把这个内部细节带进 API 响应。

- [ ] **Step 4: 语法与 lint 验证（本机能跑）**

```bash
ruby -c lib/llm/models.rb
export GEM_HOME=/tmp/rubocop-gems GEM_PATH=/tmp/rubocop-gems PATH=/tmp/rubocop-gems/bin:$PATH
rubocop --no-server --force-exclusion -a lib/llm/models.rb spec/lib/llm/models_spec.rb
```
Expected: `Syntax OK`；rubocop 无 offense（或只自动修掉可修的）

- [ ] **Step 5: Commit**

```bash
git add lib/llm/models.rb spec/lib/llm/models_spec.rb
git commit -m "feat(llm): expose per-model params from llm.yml"
```

> ⚠️ 依赖 Task 2 才能让 Step 1 的第三个用例通过（`qwen3.8-flash` 的 `params` 来自 `llm.yml`）。这两个任务的 spec 会互相依赖 —— 先做 Task 2 再回头跑这个 spec 也完全可以。

---

## Task 2: 注册 qwen 模型与 provider 参数

**Files:**
- Modify: `config/llm.yml`
- Modify: `config/llm_models.json`
- Test: `/tmp/plan_check_registry.rb`（本机 harness）

**Interfaces:**
- Consumes: Task 1 的 `params:` 读取
- Produces: 三个新模型 id 在 `llm.yml` 的 `models:` 段与 `llm_models.json` 中都存在，且在 9 个 chat feature + embedding feature 的白名单里

- [ ] **Step 1: 写验证脚本（本机可跑的 harness）**

```bash
cat > /tmp/plan_check_registry.rb <<'RUBY'
require 'yaml'
require 'json'

cfg = YAML.load_file('config/llm.yml')
registry = JSON.parse(File.read('config/llm_models.json'))
registry_ids = registry.map { |m| m['id'] }

NEW_MODELS = %w[qwen3.8-flash qwen3.7-text-embedding qwen-long].freeze
CHAT_FEATURES = %w[
  conversation_completion editor assistant copilot document_faq_generation
  conversation_faq_generation conversation_faq_matching
  help_center_article_generation onboarding_content_generation help_center_query_translation
].freeze

errors = []

NEW_MODELS.each do |id|
  errors << "#{id}: 不在 llm.yml 的 models: 段" unless cfg['models'].key?(id)
  errors << "#{id}: 不在 llm_models.json 的注册表" unless registry_ids.include?(id)
end

CHAT_FEATURES.each do |f|
  errors << "#{f}: 白名单缺 qwen3.8-flash" unless cfg['features'][f]['models'].include?('qwen3.8-flash')
end

errors << "help_center_search: 白名单缺 qwen3.7-text-embedding" unless
  cfg['features']['help_center_search']['models'].include?('qwen3.7-text-embedding')

errors << "pdf_faq_generation: 白名单缺 qwen-long" unless
  cfg['features']['pdf_faq_generation']['models'].include?('qwen-long')

# 本任务不得改动任何 default（阶段①行为必须不变）
errors << "assistant default 被改了" unless cfg['features']['assistant']['default'] == 'gpt-4.1'
errors << "editor default 被改了" unless cfg['features']['editor']['default'] == 'gpt-4.1-mini'

# params 必须挂在模型上，不是 feature 上。
# 用 cfg.dig(...) 而不是 cfg['models'][id].dig(...) —— 后者在模型缺失时抛 NoMethodError，
# 会让这个脚本在打印缺项清单之前就崩掉（T2 实现时踩到过）。
errors << "qwen3.8-flash 缺 enable_thinking params" unless
  cfg.dig('models', 'qwen3.8-flash', 'params', 'enable_thinking') == false
errors << "qwen3.7-text-embedding 缺 dimensions params" unless
  cfg.dig('models', 'qwen3.7-text-embedding', 'params', 'dimensions') == 1536

if errors.empty?
  puts 'PASS: registry 与白名单一致，default 未被改动'
else
  puts 'FAIL:'
  errors.each { |e| puts "  - #{e}" }
  exit 1
end
RUBY
ruby -I. /tmp/plan_check_registry.rb
```

Expected: `FAIL:` 并列出全部缺项（脚本先跑通，测试后通过）

- [ ] **Step 2: 在 `config/llm.yml` 的 `models:` 段追加**

在 `text-embedding-3-small` 条目之后追加（缩进与既有条目一致，两空格）：

```yaml
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
  qwen-long:
    provider: openai
    display_name: 'Qwen Long'
    credit_multiplier: 1
```

> `provider: openai` 是对的 —— DashScope 走 OpenAI 兼容协议，`Llm::FeatureRouter#provider_for` 会返回它。

- [ ] **Step 3: 在 `config/llm.yml` 各 feature 的白名单里加 `qwen3.8-flash`**

对这 10 个 feature（`conversation_completion` `editor` `assistant` `copilot` `document_faq_generation` `conversation_faq_generation` `conversation_faq_matching` `help_center_article_generation` `onboarding_content_generation` `help_center_query_translation`），在各自的 `models:` 列表**末尾**追加 `qwen3.8-flash`。

再单独处理两个：

- `help_center_search` 的 `models:` 加 `qwen3.7-text-embedding`
- `pdf_faq_generation` 的 `models:` 加 `qwen-long`

**不要动任何 `default:`。**

- [ ] **Step 4: 在 `config/llm_models.json` 追加三个条目**

追加到数组末尾（保持 JSON 合法）。三条都要有 `id` / `name` / `provider` / `family` / `context_window` / `max_output_tokens` / `modalities` / `capabilities` / `metadata`；`metadata.limit.context` 与 `metadata.limit.output` 必填，因为 `Llm::Models.temperature_for` 与 RubyLLM 会读：

```json
  {
    "id": "qwen3.8-flash",
    "name": "Qwen3.8 Flash",
    "provider": "openai",
    "family": "qwen",
    "context_window": 991000,
    "max_output_tokens": 128000,
    "modalities": { "input": ["text"], "output": ["text"] },
    "capabilities": ["function_calling"],
    "metadata": {
      "provider_id": "openai",
      "temperature": true,
      "limit": { "context": 991000, "output": 128000 }
    }
  },
  {
    "id": "qwen3.7-text-embedding",
    "name": "Qwen3.7 Text Embedding",
    "provider": "openai",
    "family": "qwen",
    "context_window": 8192,
    "max_output_tokens": 0,
    "modalities": { "input": ["text"], "output": ["text"] },
    "capabilities": [],
    "metadata": {
      "provider_id": "openai",
      "temperature": false,
      "limit": { "context": 8192, "output": 0 }
    }
  },
  {
    "id": "qwen-long",
    "name": "Qwen Long",
    "provider": "openai",
    "family": "qwen",
    "context_window": 991000,
    "max_output_tokens": 8192,
    "modalities": { "input": ["text"], "output": ["text"] },
    "capabilities": [],
    "metadata": {
      "provider_id": "openai",
      "temperature": true,
      "limit": { "context": 991000, "output": 8192 }
    }
  }
```

⚠️ `temperature: false` 用在 embedding 模型上 —— `Llm::Models.temperature_for` 会因为 `metadata[:temperature] == false` 而返回 `nil`。这是 embedding 模型的正确行为（它不取温度），与 `text-embedding-3-small` 条目保持一致：**先读一下 `text-embedding-3-small` 在 `llm_models.json` 里的 `metadata.temperature` 值，用同一个值**。

- [ ] **Step 5: 跑 harness 验证**

```bash
ruby -I. /tmp/plan_check_registry.rb
python3 -c "import json;json.load(open('config/llm_models.json'));print('JSON OK')"
```
Expected: `PASS: registry 与白名单一致，default 未被改动` + `JSON OK`

- [ ] **Step 6: Commit**

```bash
git add config/llm.yml config/llm_models.json
git commit -m "feat(captain): register qwen models in llm.yml and the ruby_llm registry"
```

---

## Task 3: 放开 installation 模型覆盖到全部 feature（含固定名单）

**Files:**
- Modify: `lib/llm/feature_router.rb`
- Test: `spec/lib/llm/feature_router_spec.rb`

**Interfaces:**
- Consumes: 无
- Produces: `Llm::FeatureRouter::PINNED_MODEL_FEATURES -> Array<String>`（冻结常量）

**背景：** 现状 `installation_model_override` 第一行是 `return unless feature_key == 'conversation_completion'`，所以 `CAPTAIN_OPEN_AI_MODEL` 只管一个 feature。本任务放开它，**同时**加固定名单挡住两个不能跟随的 feature。

⚠️ **行为不变的前提**：本任务不改 `CAPTAIN_OPEN_AI_MODEL` 的值（阶段①里它保持未设置或保持现值），所以放开后解析结果不变。

- [ ] **Step 1: 写失败的测试**

追加到 `spec/lib/llm/feature_router_spec.rb` 的最后一个 `end` 之前：

```ruby
  describe 'installation model override scope' do
    before do
      allow(ChatwootApp).to receive(:self_hosted_paid?).and_return(true)
      InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPEN_AI_MODEL').update!(value: 'custom-model')
    end

    it 'applies the installation model to a non-internal feature' do
      resolved = described_class.resolve(feature: 'editor', account: account)

      expect(resolved).to include(model: 'custom-model', source: :installation_override)
    end

    it 'applies the installation model to the assistant feature' do
      account.enable_features!('captain_integration')

      resolved = described_class.resolve(feature: 'assistant', account: account)

      expect(resolved).to include(model: 'custom-model', source: :installation_override)
    end

    it 'does not apply the installation model to pinned features' do
      resolved = described_class.resolve(feature: 'pdf_faq_generation', account: account)

      # 断言「落到该 feature 自己的 default」而不是写死某个模型名 ——
      # T6 会把 pdf_faq_generation 的 default 改成 qwen-long，写死会让这条用例在 T6 变红。
      expect(resolved).to include(model: Llm::Models.default_model_for('pdf_faq_generation'), source: :default)
    end

    it 'pins exactly the features that cannot follow the global chat model' do
      expect(described_class::PINNED_MODEL_FEATURES).to eq(%w[pdf_faq_generation audio_transcription])
    end
  end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bundle exec rspec spec/lib/llm/feature_router_spec.rb -e 'installation model override scope'`
Expected: FAIL —— `editor` 的 `source` 是 `:default` 而非 `:installation_override`；`PINNED_MODEL_FEATURES` 未定义

- [ ] **Step 3: 实现**

把 `lib/llm/feature_router.rb` 里的 `installation_model_override` 换成（只改这一行判断，方法其余部分不动）：

```ruby
    def installation_model_override(feature_key)
      return if PINNED_MODEL_FEATURES.include?(feature_key)
      return unless ChatwootApp.self_hosted_paid?

      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence
    end
```

⚠️ `PINNED_MODEL_FEATURES` **不在** `class << self` 里 —— 它定义在模块顶层（缩进两格），见下一块。放进 `class << self` 会让它变成类方法作用域下的常量，`installation_model_override` 里的引用仍能解析，但 `described_class::PINNED_MODEL_FEATURES`（测试用的常量引用）语义就不同了。

常量放在 `class << self` 之外（与既有的 `CAPTAIN_V2_ASSISTANT_MODEL` 同级，模块顶层）：

```ruby
module Llm::FeatureRouter
  class UnknownFeatureError < StandardError; end

  CAPTAIN_V2_ASSISTANT_MODEL = 'gpt-5.2'.freeze
  # pdf_faq_generation needs a model that honours DashScope's fileid:// references (qwen-long) and
  # audio_transcription is disabled, so neither may follow the installation-level chat model.
  # See the design doc §5.1: docs/superpowers/specs/2026-10-09-captain-llm-provider-migration-design.md
  PINNED_MODEL_FEATURES = %w[pdf_faq_generation audio_transcription].freeze

  class << self
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bundle exec rspec spec/lib/llm/feature_router_spec.rb`
Expected: PASS（含原有全部用例）

> 本机跑不了。本机能做的是 Step 5。

- [ ] **Step 5: 本机验证**

```bash
ruby -c lib/llm/feature_router.rb
export GEM_HOME=/tmp/rubocop-gems GEM_PATH=/tmp/rubocop-gems PATH=/tmp/rubocop-gems/bin:$PATH
rubocop --no-server --force-exclusion -a lib/llm/feature_router.rb spec/lib/llm/feature_router_spec.rb
```

- [ ] **Step 6: Commit**

```bash
git add lib/llm/feature_router.rb spec/lib/llm/feature_router_spec.rb
git commit -m "feat(llm): apply the installation model override to all unpinned features"
```

---

## Task 4: `openai_use_system_role = true`

**Files:**
- Modify: `lib/llm/config.rb`
- Test: `spec/lib/llm/config_spec.rb`

**Interfaces:**
- Consumes: 无
- Produces: 无（全局 RubyLLM 配置）

**背景：** `ruby_llm` 2.0.0 的 `lib/ruby_llm/protocols/chat_completions/chat.rb` 是 `@config.openai_use_system_role ? 'system' : 'developer'`。Chatwoot 设了 `openai_protocol = :chat_completions` 但没设这个开关 → 默认发 `developer` → DashScope 全系 400。对 OpenAI 无害（`system` 是合法 role）。

- [ ] **Step 1: 写失败的测试**

追加到 `spec/lib/llm/config_spec.rb` 的最后一个 `end` 之前：

```ruby
  describe 'ruby_llm OpenAI role configuration' do
    it 'sends the system role instead of developer' do
      described_class.reset!
      described_class.initialize!

      expect(RubyLLM.config.openai_use_system_role).to be(true)
    end
  end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bundle exec rspec spec/lib/llm/config_spec.rb -e 'sends the system role'`
Expected: FAIL —— expected true, got nil

- [ ] **Step 3: 实现**

在 `lib/llm/config.rb` 的 `configure_ruby_llm` 里，`config.openai_protocol = :chat_completions` 之后加一行：

```ruby
        config.openai_protocol = :chat_completions
        # ruby_llm's chat_completions protocol sends the 'developer' role by default; DashScope
        # only accepts 'system'. OpenAI accepts both, so enable it globally rather than branching.
        config.openai_use_system_role = true
```

- [ ] **Step 4: 本机验证**

```bash
ruby -c lib/llm/config.rb
export GEM_HOME=/tmp/rubocop-gems GEM_PATH=/tmp/rubocop-gems PATH=/tmp/rubocop-gems/bin:$PATH
rubocop --no-server --force-exclusion -a lib/llm/config.rb spec/lib/llm/config_spec.rb
```

- [ ] **Step 5: Commit**

```bash
git add lib/llm/config.rb spec/lib/llm/config_spec.rb
git commit -m "fix(llm): send the system role so OpenAI-compatible providers accept requests"
```

---

## Task 5: 三处调用点应用 `model_params`

**Files:**
- Modify: `lib/captain/base_task_service.rb`（`build_chat`）
- Modify: `enterprise/app/models/concerns/agentable.rb`（`agent`）
- Modify: `enterprise/app/services/captain/llm/embedding_service.rb`（`get_embedding`）
- Test: `spec/lib/captain/base_task_service_spec.rb`、`spec/enterprise/models/concerns/agentable_spec.rb`、`spec/enterprise/services/captain/llm/embedding_service_spec.rb`

**Interfaces:**
- Consumes: `Llm::Models.model_params(model_name) -> Hash`（Task 1）
- Produces: 无新接口

⚠️ **空 hash 必须短路**：阶段①里 OpenAI 模型的 `model_params` 返回 `{}`。`chat.with_provider_options({})` 会把 provider options 清空成空 hash，不是无操作。三处都要用 `if params.any?` 保护。

- [ ] **Step 1: 改 `lib/captain/base_task_service.rb`**

`build_chat` 现状：

```ruby
  def build_chat(context, model:, messages:, schema: nil, tools: [])
    chat = context.chat(model: model)
    system_msg = messages.find { |m| m[:role] == 'system' }
    chat.with_instructions(system_msg[:content]) if system_msg
    chat.with_schema(schema) if schema
```

改为（在 `with_schema` 之后插入两行）：

```ruby
  def build_chat(context, model:, messages:, schema: nil, tools: [])
    chat = context.chat(model: model)
    system_msg = messages.find { |m| m[:role] == 'system' }
    chat.with_instructions(system_msg[:content]) if system_msg
    chat.with_schema(schema) if schema

    provider_params = Llm::Models.model_params(model)
    chat.with_provider_options(provider_params) if provider_params.any?
```

- [ ] **Step 2: 改 `enterprise/app/models/concerns/agentable.rb#agent`**

现状：

```ruby
  def agent(runtime_configuration: nil, runtime_agent_name: nil)
    model = agent_model
    Agents::Agent.new(
      name: runtime_agent_name || agent_name,
      instructions: ->(context) { agent_instructions(context, runtime_configuration: runtime_configuration) },
      tools: agent_tools,
      model: model,
      temperature: Llm::Models.temperature_for(model, temperature.presence&.to_f || DEFAULT_TEMPERATURE),
      response_schema: agent_response_schema
    )
  end
```

改为：

```ruby
  def agent(runtime_configuration: nil, runtime_agent_name: nil)
    model = agent_model
    provider_params = Llm::Models.model_params(model)
    Agents::Agent.new(
      name: runtime_agent_name || agent_name,
      instructions: ->(context) { agent_instructions(context, runtime_configuration: runtime_configuration) },
      tools: agent_tools,
      model: model,
      temperature: Llm::Models.temperature_for(model, temperature.presence&.to_f || DEFAULT_TEMPERATURE),
      response_schema: agent_response_schema,
      **(provider_params.any? ? { params: provider_params } : {})
    )
  end
```

- [ ] **Step 3: 改 `enterprise/app/services/captain/llm/embedding_service.rb#get_embedding`**

现状 `get_embedding`：

```ruby
  def get_embedding(content, model: @embedding_model)
    return [] if content.blank?

    instrument_embedding_call(instrumentation_params(content, model)) do
      RubyLLM.embed(content, model: model).vectors
    end
  rescue RubyLLM::Error => e
```

改为：

```ruby
  def get_embedding(content, model: @embedding_model)
    return [] if content.blank?

    provider_params = Llm::Models.model_params(model)

    instrument_embedding_call(instrumentation_params(content, model)) do
      RubyLLM.embed(content, model: model, **provider_params).vectors
    end
  rescue RubyLLM::Error => e
```

（`RubyLLM.embed` 原生支持 `dimensions:` 关键字参数。）

- [ ] **Step 4: 加测试**

在这三个 spec 各自末尾加一条，验证 params 被透传。以 `base_task_service_spec.rb` 为例：

```ruby
  describe 'provider params passthrough' do
    it 'passes enable_thinking to the chat when the model declares it' do
      chat = instance_double(RubyLLM::Chat, with_instructions: nil, with_schema: nil)
      allow(chat).to receive(:with_provider_options).with(enable_thinking: false)
      context = instance_double(RubyLLM::Context, chat: chat)
      service = described_class.new(account: account)

      service.send(:build_chat, context, model: 'qwen3.8-flash',
                                           messages: [{ role: 'system', content: 'x' }])

      expect(chat).to have_received(:with_provider_options).with(enable_thinking: false)
    end

    it 'does not call with_provider_options when the model declares none' do
      chat = instance_double(RubyLLM::Chat, with_instructions: nil, with_schema: nil)
      allow(chat).to receive(:with_provider_options)
      context = instance_double(RubyLLM::Context, chat: chat)
      service = described_class.new(account: account)

      service.send(:build_chat, context, model: 'gpt-4.1',
                                           messages: [{ role: 'system', content: 'x' }])

      expect(chat).not_to have_received(:with_provider_options)
    end
  end
```

同理给 `agentable_spec.rb`（断言 `Agents::Agent.new` 收到 `params:`）与 `embedding_service_spec.rb`（断言 `RubyLLM.embed` 收到 `dimensions: 1536`）各加一条。**这两个 spec 的实际构造方式须先读现有文件照抄其 stub 风格**（不要照搬上面的 `instance_double`，`agentable_spec.rb` 用的是 `Llm::FeatureRouter` stub + `account.enable_features!`）。

- [ ] **Step 5: 本机验证**

```bash
for f in lib/captain/base_task_service.rb enterprise/app/models/concerns/agentable.rb enterprise/app/services/captain/llm/embedding_service.rb; do ruby -c $f; done
export GEM_HOME=/tmp/rubocop-gems GEM_PATH=/tmp/rubocop-gems PATH=/tmp/rubocop-gems/bin:$PATH
rubocop --no-server --force-exclusion -a lib/captain/base_task_service.rb enterprise/app/models/concerns/agentable.rb enterprise/app/services/captain/llm/embedding_service.rb
```

- [ ] **Step 6: Commit**

```bash
git add lib/captain/base_task_service.rb enterprise/app/models/concerns/agentable.rb enterprise/app/services/captain/llm/embedding_service.rb spec/
git commit -m "feat(captain): pass per-model provider params to ruby_llm and agents"
```

---

## ✅ 阶段①完成后的验证（本机 + 工具链机器）

- [ ] `bundle exec rspec spec/lib/llm spec/enterprise/models/concerns/agentable_spec.rb spec/enterprise/services/captain/llm/embedding_service_spec.rb` 全绿
- [ ] **在 `:81` 上构建并部署**（endpoint 与 `CAPTAIN_OPEN_AI_MODEL` 保持原值）：

```bash
deploy/upstream-comparison/deploy.sh --build-only   # 约 40 分钟
# 先跑 spec §10 的第 1、2、4、5、6 条 —— 必须与改动前一致
deploy/upstream-comparison/deploy.sh                # 确认后部署
```

**这一步不通过就不要进阶段②。**

---

## Task 6: 移除 `CAPTAIN_V2_ASSISTANT_MODEL` 硬编码 + 改写 feature 默认模型

**Files:**
- Modify: `lib/llm/feature_router.rb`
- Modify: `enterprise/app/fields/captain_model_overrides_field.rb`
- Modify: `enterprise/app/models/concerns/agentable.rb`（`agent_model`）
- Modify: **`app/controllers/api/v1/accounts/captain/preferences_controller.rb`**（`#default_model_for` 里有一行特判引用了 `CAPTAIN_V2_ASSISTANT_MODEL` —— 删常量时必须一并删掉，否则 `NameError`）
- Modify: `config/llm.yml`（各 feature 的 `default:`）
- Test: `spec/lib/llm/feature_router_spec.rb`、`spec/lib/llm/models_spec.rb`、`spec/enterprise/models/concerns/agentable_spec.rb`、**`spec/controllers/api/v1/accounts/captain/preferences_controller_spec.rb`**

> ⚠️ 这份清单**曾经漏了** `preferences_controller.rb` 与它的 spec —— 那处引用是 T6 实现者 grep 出来才发现的。**动 `CAPTAIN_V2_ASSISTANT_MODEL` 前先 `grep -rn CAPTAIN_V2_ASSISTANT_MODEL app lib enterprise spec`**，别信清单。

**Interfaces:**
- Consumes: `Llm::FeatureRouter::PINNED_MODEL_FEATURES`（Task 3）
- Produces: 无（删除 `CAPTAIN_V2_ASSISTANT_MODEL` 与 `captain_assistant_model`）

**背景：** 删掉硬编码后，captain 账号的 assistant 默认模型改由 `llm.yml` 的 `assistant.default` 决定 —— **这是行为变化**（`gpt-5.2` → 新默认），所以放在阶段②，与 default 改写一起落地。

- [ ] **Step 1: 改 `lib/llm/feature_router.rb`**

删掉模块顶层的 `CAPTAIN_V2_ASSISTANT_MODEL = 'gpt-5.2'.freeze`，删掉 `captain_assistant_model` 方法，并把 `model_and_source` 的最后一行改为：

```ruby
    def model_and_source(account, feature_key)
      account_model = account_model_override(account, feature_key)
      return [account_model, :account_override] if account_model.present?

      installation_model = installation_model_override(feature_key)
      return [installation_model, :installation_override] if installation_model.present?

      [Llm::Models.default_model_for(feature_key), :default]
    end
```

- [ ] **Step 2: 改 `enterprise/app/fields/captain_model_overrides_field.rb#default_model_id`**

```ruby
  def default_model_id(feature_key)
    Llm::Models.default_model_for(feature_key)
  end
```

- [ ] **Step 3: 简化 `enterprise/app/models/concerns/agentable.rb#agent_model`**

现状：

```ruby
  def agent_model
    route = Llm::FeatureRouter.resolve(feature: 'assistant', account: account)
    return route[:model] if route[:source] == :account_override || account&.feature_enabled?('captain_integration')

    installation_model.presence || route[:model]
  end
```

改为：

```ruby
  def agent_model
    Llm::FeatureRouter.resolve(feature: 'assistant', account: account)[:model]
  end
```

同时删掉只被它使用的私有方法 `installation_model`：

```ruby
  def installation_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
  end
```

（`installation_model_override` 已经在 `FeatureRouter` 里覆盖了这个逻辑，这里重复了。）

⚠️ **但这不是纯粹的重复** —— `FeatureRouter` 那份**带 `self_hosted_paid?` 门槛**，而 `agentable.rb` 删掉的这份**没有**。所以非 paid 的自建实例若设了 `CAPTAIN_OPEN_AI_MODEL`，assistant 会从 installation 模型变成 `llm.yml` 的默认值。T6 的 reviewer 做过可达性分析：还需账号**未开** `captain_integration`，而老方法对开了 Captain 的账号已提前 return，所以生产路径上不可达；我们这台是 paid，完全不受影响。**记在这里是因为原文低估了它。**

- [ ] **Step 4: 改 `config/llm.yml` 的 `default:`**

| feature | 新 default |
|---|---|
| `assistant` | `qwen3.8-flash` |
| `copilot` | `qwen3.8-flash` |
| `editor` | `qwen3.8-flash` |
| `conversation_completion` | `qwen3.8-flash` |
| `conversation_faq_generation` | `qwen3.8-flash` |
| `conversation_faq_matching` | `qwen3.8-flash` |
| `document_faq_generation` | `qwen3.8-flash` |
| `help_center_article_generation` | `qwen3.8-flash` |
| `onboarding_content_generation` | `qwen3.8-flash` |
| `help_center_query_translation` | `qwen3.8-flash` |
| `help_center_search` | `qwen3.7-text-embedding` |
| `pdf_faq_generation` | `qwen-long` |
| `audio_transcription` | **不动**（停用） |

- [ ] **Step 5: 修被改坏的既有测试**

`spec/lib/llm/feature_router_spec.rb` 里这两条必须改（它们断言的是被删掉的硬编码）：

- `'resolves GPT-5.2 as the assistant default when Captain V2 is enabled without storing an account override'`
  → 改成断言走 `llm.yml` 的 `assistant.default`：

```ruby
    it 'resolves the configured assistant default when Captain V2 is enabled without an account override' do
      account.enable_features!('captain_integration')

      resolved = described_class.resolve(feature: 'assistant', account: account)

      expect(resolved).to include(
        feature: 'assistant',
        provider: 'openai',
        model: 'qwen3.8-flash',
        source: :default
      )
      expect(account.reload.captain_models).to be_nil
    end
```

- `spec/lib/llm/models_spec.rb` 里这两条：
  - `'routes each FAQ operation independently'` → 期望值改成新的 default
  - `'offers only supported OpenAI models for conversation completion'` → 改成包含 `qwen3.8-flash` 的完整列表

- [ ] **Step 6: 本机验证**

```bash
ruby -c lib/llm/feature_router.rb
ruby -I. /tmp/plan_check_registry.rb   # 会因 default 已变而报错，属预期 —— 忽略 default 那两行断言
python3 -c "
import yaml;c=yaml.safe_load(open('config/llm.yml'))
assert c['features']['assistant']['default']=='qwen3.8-flash'
assert c['features']['pdf_faq_generation']['default']=='qwen-long'
assert c['features']['help_center_search']['default']=='qwen3.7-text-embedding'
print('defaults OK')"
export GEM_HOME=/tmp/rubocop-gems GEM_PATH=/tmp/rubocop-gems PATH=/tmp/rubocop-gems/bin:$PATH
rubocop --no-server --force-exclusion -a lib/llm/feature_router.rb enterprise/app/fields/captain_model_overrides_field.rb enterprise/app/models/concerns/agentable.rb
```

- [ ] **Step 7: Commit**

```bash
git add lib/llm/feature_router.rb enterprise/app/fields/captain_model_overrides_field.rb enterprise/app/models/concerns/agentable.rb config/llm.yml spec/
git commit -m "refactor(captain): drop the hardcoded assistant model and route features to qwen"
```

---

## Task 7: PDF 两个 service 改用 DashScope Files API

**Files:**
- Modify: `enterprise/app/services/captain/llm/pdf_processing_service.rb`
- Modify: `enterprise/app/services/captain/llm/paginated_faq_generator_service.rb`
- Test: `spec/enterprise/services/captain/llm/pdf_processing_service_spec.rb`、`spec/enterprise/services/captain/llm/paginated_faq_generator_service_spec.rb`

**Interfaces:**
- Consumes: `Llm::Models.model_params`（Task 1，本任务不用）；`Llm::FeatureRouter`（Task 6 之后 `pdf_faq_generation` 默认 = `qwen-long`）
- Produces: `Captain::Llm::PaginatedFaqGeneratorService::FILE_REFERENCE_MODELS -> Array<String>`

**背景：** DashScope 的 `fileid://` 只在 `qwen-long` 上生效，其他模型**静默忽略**（FAQ 会变成模型自带知识编的内容且不报错）。所以这里必须有一个响亮失败的护栏。

- [ ] **Step 1: 改上传的 `purpose`**

`enterprise/app/services/captain/llm/pdf_processing_service.rb`，`upload_pdf_to_openai`：

```ruby
        response = @client.files.upload(
          parameters: {
            file: temp_file,
            purpose: 'assistants'
          }
        )
```

改为：

```ruby
        response = @client.files.upload(
          parameters: {
            file: temp_file,
            purpose: 'file-extract'
          }
        )
```

- [ ] **Step 2: 改引用方式**

`enterprise/app/services/captain/llm/paginated_faq_generator_service.rb`：**删掉** `build_user_content` 整个方法，并把 `build_chunk_parameters` 改为：

```ruby
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

（`json_object` 要求 prompt 里出现 "json" 字样 —— `SystemPromptsService.paginated_faq_generator` 已满足，别改动那个 prompt 的这一点。）

- [ ] **Step 3: 加模型护栏**

在 `paginated_faq_generator_service.rb` 的类顶部（`MAX_ITERATIONS` 之后）加常量：

```ruby
  # fileid:// is silently ignored by models that do not support it: they answer from their own
  # knowledge instead of erroring. Fail loudly rather than let invented FAQs reach the knowledge
  # base. See the design doc §5.1.
  FILE_REFERENCE_MODELS = %w[qwen-long].freeze
```

并在 `initialize` 里 `@model = ...` 那一行之后加：

```ruby
  def initialize(document, options = {})
    super()
    @document = document
    @language = options[:language] || 'english'
    @pages_per_chunk = options[:pages_per_chunk] || DEFAULT_PAGES_PER_CHUNK
    @max_pages = options[:max_pages] # Optional limit from UI
    @total_pages_processed = 0
    @iterations_completed = 0
    @model = Llm::FeatureRouter.resolve(feature: 'pdf_faq_generation', account: document.account)[:model]

    return if FILE_REFERENCE_MODELS.include?(@model)

    raise CustomExceptions::Pdf::FaqGenerationError,
          "pdf_faq_generation 必须使用支持 fileid:// 的模型，当前为 #{@model} —— 该模型会静默忽略文件内容"
  end
```

- [ ] **Step 4: 加/改测试**

`paginated_faq_generator_service_spec.rb` 加两条：

```ruby
  describe 'model guard' do
    it 'raises when the resolved model cannot read fileid:// references' do
      allow(Llm::FeatureRouter).to receive(:resolve).and_return(model: 'qwen3.8-flash')

      expect { described_class.new(document) }
        .to raise_error(CustomExceptions::Pdf::FaqGenerationError, /fileid:\/\//)
    end

    it 'accepts qwen-long' do
      allow(Llm::FeatureRouter).to receive(:resolve).and_return(model: 'qwen-long')

      expect { described_class.new(document) }.not_to raise_error
    end
  end
```

再改一条现有断言（若它检查 `build_user_content` 或 `file:` 部件）为断言 system message 里的 `fileid://`：

```ruby
    it 'references the uploaded file through a fileid system message' do
      allow(Llm::FeatureRouter).to receive(:resolve).and_return(model: 'qwen-long')
      service = described_class.new(document)

      params = service.send(:build_chunk_parameters, 1, 10)

      expect(params[:messages].first).to eq(role: 'system', content: "fileid://#{document.openai_file_id}")
    end
```

`pdf_processing_service_spec.rb` 里的 `purpose: 'assistants'` 断言改为 `'file-extract'`。

- [ ] **Step 5: 本机验证**

```bash
ruby -c enterprise/app/services/captain/llm/pdf_processing_service.rb
ruby -c enterprise/app/services/captain/llm/paginated_faq_generator_service.rb
grep -n "build_user_content" enterprise/app/services/captain/llm/paginated_faq_generator_service.rb  # 必须无输出（死代码已删）
export GEM_HOME=/tmp/rubocop-gems GEM_PATH=/tmp/rubocop-gems PATH=/tmp/rubocop-gems/bin:$PATH
rubocop --no-server --force-exclusion -a enterprise/app/services/captain/llm/
```

- [ ] **Step 6: Commit**

```bash
git add enterprise/app/services/captain/llm/ spec/enterprise/services/captain/llm/
git commit -m "feat(captain): read PDFs through DashScope files instead of OpenAI"
```

---

## Task 8: 挂载 `llm.yml` 与 `llm_models.json` 为 volume

**Files:**
- Modify: `deploy/upstream-comparison/docker-compose.yml`
- Modify: `deploy/upstream-comparison/README.md`

**Interfaces:**
- Consumes: 无
- Produces: 容器内 `/app/config/llm.yml` 与 `/app/config/llm_models.json` 来自宿主机

- [ ] **Step 1: 先读 README（CLAUDE.md 的硬性要求）**

```bash
cat deploy/upstream-comparison/README.md
```

确认：该主机 `docker compose` 是否需要 `sudo`、compose 文件的调用方式、订阅检查屏蔽怎么做的。**不要跳过这一步。**

- [ ] **Step 2: 确定挂载源路径**

compose 只把工作树当**构建上下文**交给服务器 daemon（构建完丢弃），运行期容器里的 `/app/config/*` 来自镜像。所以挂载源必须是**服务器上持久存在的路径**。

到服务器上看 compose 文件的实际位置与目录布局，再决定挂载源。**不要写相对路径** —— 在 `/tmp` 或本地验证：

```bash
ssh ubuntu@32.236.75.213 'ls -la /home/ubuntu/ | head -20; find /home/ubuntu -maxdepth 3 -name "docker-compose*.yml" 2>/dev/null'
```

若服务器上没有合适的常驻目录，需要先建一个（例如 `/home/ubuntu/chatwoot-config/`）并把当前镜像里的这两个文件拷出来：

```bash
ssh ubuntu@32.236.75.213 'bash -s' <<'EOS'
set -e
IMG=$(docker ps --filter name=chatwoot-upstream --format '{{.Image}}' | head -1)
mkdir -p ~/chatwoot-config
docker run --rm -v ~/chatwoot-config:/out --entrypoint sh "$IMG" \
  -c 'cp /app/config/llm.yml /app/config/llm_models.json /out/'
ls -la ~/chatwoot-config/
EOS
```

- [ ] **Step 3: 加 volume**

在 `deploy/upstream-comparison/docker-compose.yml` 的 app/rails/sidekiq 服务（凡是加载这个配置的进程都要挂）下加：

```yaml
    volumes:
      - /home/ubuntu/chatwoot-config/llm.yml:/app/config/llm.yml:ro
      - /home/ubuntu/chatwoot-config/llm_models.json:/app/config/llm_models.json:ro
```

⚠️ **用 Step 2 实际确认的路径替换上面两条。** 若该服务已有 `volumes:` 列表，是追加而不是覆盖。

- [ ] **Step 4: 在 README 登记**

在 `deploy/upstream-comparison/README.md` 加一节：

```markdown
## 挂载的 LLM 配置（需跟随上游手动同步）

`config/llm.yml` 与 `config/llm_models.json` 通过 volume 从 `~/chatwoot-config/` 挂入容器，
使换模型不必重建镜像。

⚠️ 这两个文件因此与镜像版本脱钩。**上游若改动它们的结构（例如 `llm.yml` 新增必填字段），
宿主机那份会过期并导致启动失败。** 跟进上游时需手动 diff 并同步这两份。
```

- [ ] **Step 5: 验证挂载生效**

```bash
ssh ubuntu@32.236.75.213 'cd ~/chatwoot-config && echo "# probe" >> llm.yml && docker compose -f <compose路径> restart rails && sleep 5 && docker compose -f <compose路径> logs rails --tail 20'
```

Expected: 启动正常；日志里没有 YAML/加载错误。验证后**把 `# probe` 那行删掉并再重启一次**。

- [ ] **Step 6: Commit**

```bash
git add deploy/upstream-comparison/docker-compose.yml deploy/upstream-comparison/README.md
git commit -m "chore(deploy): mount the llm configs so model swaps skip an image rebuild"
```

---

## Task 9: 执行迁移（切 endpoint + 重算向量 + 重传 PDF）

**这是整个计划里风险最高的一步。** 前 8 个任务都是可回滚的代码/配置改动，这一步动生产数据。

**Files:**
- 无代码改动；产出 `docs/superpowers/plans/2026-10-09-migration-runbook.md`（本次执行的记录）

**Interfaces:**
- Consumes: Task 1–8 全部
- Produces: 无

- [ ] **Step 1: 先量 PDF 文档规模（spec §8.5 的待办）**

```bash
ssh ubuntu@32.236.75.213 'docker compose -f <compose> exec -T postgres psql -U postgres -d chatwoot -c "
SELECT count(*) AS docs_total,
       count(openai_file_id) AS with_fileid
FROM captain_documents;"'
```

把结果记进 runbook。若 `with_fileid` 是 0，跳过 Step 6。

- [ ] **Step 2: 备份（回滚用）**

```bash
ssh ubuntu@32.236.75.213 '
  cd ~ && mkdir -p backup-$(date +%F) && cd backup-$(date +%F)
  docker compose -f <compose> exec -T postgres pg_dump -U postgres -d chatwoot \
    -t captain_assistant_responses -t captain_faq_suggestions -t article_embeddings -t captain_documents \
    > pre-migration.sql
  ls -la'
```

- [ ] **Step 3: 改 InstallationConfig**

在 `:81` 的 Super Admin → App Configs → Captain 改三项：

| 配置 | 值 |
|---|---|
| `CAPTAIN_OPEN_AI_ENDPOINT` | `https://dashscope.aliyuncs.com/compatible-mode` （**不带 `/v1`**） |
| `CAPTAIN_OPEN_AI_API_KEY` | DashScope 的 key |
| `CAPTAIN_OPEN_AI_MODEL` | `qwen3.8-flash` |
| `CAPTAIN_EMBEDDING_MODEL` | `qwen3.7-text-embedding` |

- [ ] **Step 4: 停 worker（生产环境必做；`:81` 可跳过）**

- [ ] **Step 5: 重算向量**

```bash
ssh ubuntu@32.236.75.213 'cd <app目录> && docker compose -f <compose> exec -T rails bundle exec rails runner "
Captain::AssistantResponse.find_each { |r| Captain::Llm::UpdateEmbeddingJob.perform_now(r, %(#{r.question}: #{r.answer})) }
Captain::FaqSuggestion.find_each     { |s| Captain::Llm::UpdateEmbeddingJob.perform_now(s, %(#{s.question}: #{s.answer})) }
ArticleEmbedding.find_each           { |a| Captain::Llm::UpdateEmbeddingJob.perform_now(a, a.term) }
puts %(done)"'
```

⚠️ `perform_now` 串行执行，避免打爆 DashScope 限流。**先估一下行数**（Step 1 已有 `captain_assistant_responses` 等的规模），超过几千行要考虑分批或后台跑。

- [ ] **Step 6: REINDEX 三个 ivfflat 索引**

**必须在重算完成后、恢复服务前做** —— 换 embedding 模型后整个向量分布变了，不重建索引召回会明显下降：

```bash
ssh ubuntu@32.236.75.213 'docker compose -f <compose> exec -T postgres psql -U postgres -d chatwoot -c "
REINDEX INDEX vector_idx_knowledge_entries_embedding;
REINDEX INDEX vector_idx_captain_faq_suggestions_embedding;
REINDEX INDEX index_article_embeddings_on_embedding;"'
```

- [ ] **Step 7: 清空 PDF file id 并重传**

```bash
ssh ubuntu@32.236.75.213 'cd <app目录> && docker compose -f <compose> exec -T rails bundle exec rails runner "
n = Captain::Document.where.not(openai_file_id: nil).update_all(openai_file_id: nil)
puts %(cleared #{n})"'
```

然后触发重传（逐条 `Captain::Llm::PdfProcessingService.new(doc).process`，或让 `crawl_job` 重跑）。**每传一条立刻验证拿到的 id 以 `file-fe-` 开头** —— 若仍是 `file-` 开头，说明 endpoint 没生效。

- [ ] **Step 8: 重启进程（刷新 embedding 的全局 RubyLLM config）**

`Llm::Config.reset!` 全仓库无调用点，`initialize!` 是 `@initialized` 记忆化的 —— **embedding 走全局 config，必须重启进程才生效**。

```bash
ssh ubuntu@32.236.75.213 'sudo docker compose -f <compose> restart rails sidekiq'
```

- [ ] **Step 9: 恢复 worker（生产环境）**

- [ ] **Step 10: 跑 spec §10 的 8 条验证**

逐条记录结果，特别是：

| # | 检查 | 记录 |
|---|---|---|
| 1 | Playground 能回话，响应 <10s（>15s 说明 `enable_thinking: false` 没生效） | |
| 2 | FAQ 生成能出条 | |
| 3 | `faq_lookup` 能查到相关条目 | |
| 4 | PDF：上传拿到 `file-fe-` id；**抽 3 条 FAQ 回原文核对**（防静默编造）；`pdf_faq_generation` 模型是 `qwen-long` | |
| 5 | Super Admin → Captain models 页面能打开 | |
| 6 | 编辑器 AI 改写可用 | |
| 7 | 日志无 `developer is not one of` / `ModelNotFoundError` / `This response_format type is unavailable` | |
| 8 | **延迟**：每次调用额外 ~260ms = 正常（连接复用）；~800ms = 每次新建 TLS，**需要处理连接复用** | |

- [ ] **Step 11: Commit runbook**

```bash
git add docs/superpowers/plans/2026-10-09-migration-runbook.md
git commit -m "docs(captain): record the dashscope migration runbook and results"
```

---

## Task 10: 推生产

**Files:**
- 无代码改动

- [ ] **Step 1: 确认 `:81` 的 8 条验证全过**

任一不过就停下，不要推生产。

- [ ] **Step 2: 用同一个 commit tag 构建生产镜像**

不要用 `:81` 之外的任何 commit。

- [ ] **Step 3: 在生产上重复 Task 9 的 Step 1–9**

差异：**生产必须停机迁移**（停 worker → 重算 → REINDEX → 恢复），`:81` 可以不停。

- [ ] **Step 4: 跑同一套 8 条验证**

---

## 完成后的运维认知（不要忘）

落地后换模型/换 provider 分四档，详见 spec §13。最容易记错的两点：

1. **"零重建"不等于"零操作"** —— 切 provider 要 `docker compose restart`（embedding 走全局 config，必须重启进程），还要重算向量。
2. **PDF 不在可移植范围内** —— `fileid://` 是 DashScope 专有，切回 OpenAI 要改代码（Task 7 反向）。这是选路 B 的已知代价。

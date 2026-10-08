# 套餐卡片对齐 novyro_plan_group 契约 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让本仓库发出的套餐卡片消息逐字段满足 App 端 `ChatwootCardItem` 的冻结契约（`novyro_plan_group`），并把"模型决策、服务端对账"的流程从 ai-bridge 落回 Chatwoot。

**Architecture:** 卡片由 Captain 工具 `create_purchase_action` 组卡并投递：模型只给 `product_id` / `sku_ids`（顺序即主次）/ `reason` / `label`，流量、有效期、价格与 checkout 链接一律取自该次上游返回。字段形状由 `ContentAttributeValidator` 的 `novyro_plan_group` 分支强制；文案来自随本仓库提交的 41 语言字典（`MobileChat::CardCopy`），刻意不走 Chatwoot I18n。

**Tech Stack:** Rails 7.x、`ai-agents`（`Agents::Tool` / RubyLLM 2.0 的 `parameter` DSL）、RSpec + WebMock + FactoryBot、YAML 数据文件。

**Spec:** `docs/superpowers/specs/2026-10-08-mobile-chat-plan-cards-design.md`

## Global Constraints

- **本机没有 Ruby 工具链**：`bundle exec rspec` / `rubocop` 全部不可用（没有 rbenv、Ruby 3.4.4、PostgreSQL、Redis）。所以：
  - 本机能跑的验证只有 `ruby -c <file>`、`ruby -ryaml -e '...'`、以及 `node` 驱动的数据比对。
  - **spec 照写，但标为未执行**；汇报时必须分开写"跑了哪些静态检查"和"spec 未执行"，不得暗示测试通过。
  - 任何形如 `bundle exec rspec …` 的步骤都要注明「需在有工具链的环境执行」。
- 字段上限与形状（取自 spec §2，校验器按这些值实现）：`title` ≤160、`description` ≤500、`badge` ≤40、fact `label` ≤40 / `value` ≤120、action `text` ≤120、uri ≤2048；`media_url` 必须是空串；items 1..5；facts 1..3，icon ∈ `wifi|calendar|wallet`；actions 恰好 1 个且 `type == "link"`；uri path 恰好 `/app-actions/checkout`，query 恰好 `{goods_id, sku_id, catalog_env}`，`catalog_env ∈ {dev,test,prod}`。
- **不发** `country_image`（可选字段，App 1.0.34 不读它，发了只会多一个校验失败面）与 `customer_support_content_sha256`；**不做** `novyro_web_plan_list` 变体。
- 文案字典只搬卡片用到的 10 个键：`primary/alternative/data/unlimited/validity/dayUnit/price/cta/description/plan`。不动 `config/locales/**` 与 `config/initializers/languages.rb`。
- 只改本仓库；不改 `esimgo-mobile` / `esimgo-web`（客户端待办见 spec §7）。
- 提交信息用 Conventional Commits、英文主题，不带 Claude 署名。
- 每个任务结束都提交一次；`git add` 只加本任务涉及的文件。

---

## 文件结构

| 文件 | 责任 |
|---|---|
| `config/mobile_chat/card_copy.yml`（新增） | 41 语言 × 10 键的文案数据，从 ai-bridge 的 `purchaseCopy.js` 机械生成 |
| `app/services/mobile_chat/card_copy.rb`（新增） | `MobileChat::CardCopy`：按 appLocale 取文案（精确 → 前缀 → en）+ 模型自由文本的 sanitizer |
| `app/models/concerns/content_attribute_validator.rb`（改） | 新增 `novyro_plan_group` 分支，强制卡片字段形状 |
| `app/services/mobile_chat/captain_toolkit.rb`（改） | 上游 header 带 locale/currency；新增 `purchase_actions` 组卡；删除旧的 `plan_cards` 一系 |
| `enterprise/lib/captain/tools/mobile_chat_tool.rb`（改） | `post_cards` 发 `variant: 'novyro_plan_group'` 的消息 |
| `enterprise/lib/captain/tools/recommend_plan_tool.rb`（改） | 只回数据，不再发卡 |
| `enterprise/lib/captain/tools/create_purchase_action_tool.rb`（新增） | 新工具：收模型决策 → 调 toolkit → 发卡 |
| `config/agents/tools.yml`（改） | 注册 `create_purchase_action` |
| `spec/services/mobile_chat/card_copy_spec.rb`（新增） | 字典回退链 + sanitizer |
| `spec/models/concerns/content_attribute_validator_spec.rb`（新增） | `novyro_plan_group` 分支的接受与逐条拒绝 |
| `spec/services/mobile_chat/captain_toolkit_spec.rb`（改） | `purchase_actions` 的组卡/复核/顺序/截断 |
| `spec/enterprise/lib/captain/tools/create_purchase_action_tool_spec.rb`（新增） | 工具投递与无会话降级 |

---

### Task 1: 文案字典与 sanitizer

**Files:**
- Create: `config/mobile_chat/card_copy.yml`
- Create: `app/services/mobile_chat/card_copy.rb`
- Test: `spec/services/mobile_chat/card_copy_spec.rb`

**Interfaces:**
- Consumes: 无
- Produces:
  - `MobileChat::CardCopy.copy_for(locale) → Hash`（键为 String，含 `primary/alternative/data/unlimited/validity/dayUnit/price/cta/description/plan`；en 缺失时抛 `CustomExceptions::MobileChat::NotConfigured`）
  - `MobileChat::CardCopy.sanitize_description(value, fallback) → String`（上限 500）
  - `MobileChat::CardCopy.sanitize_action_text(value, fallback) → String`（上限 120）
  - `MobileChat::CardCopy.dictionaries → Hash`（公开，便于 spec 替换）

- [ ] **Step 1: 生成字典文件**

把 ai-bridge 的字典机械转成 YAML（只取用到的 10 个键；`JSON.stringify` 的转义规则与 YAML 双引号字符串兼容）。**locale 键必须加引号**：Psych 是 YAML 1.1，裸 `no:` 会被解析成布尔 `false`，挪威语整块就取不到了（实测过：41 个键里 40 个 String、一个是 `false`）：

```bash
mkdir -p config/mobile_chat
node -e '
const fs = require("fs");
const { CARD_COPY } = require("/Users/zhoujundi/Repo/esim/customer-service-platform/apps/ai-bridge/src/mobileChat/purchaseCopy.js");
const KEYS = ["primary","alternative","data","unlimited","validity","dayUnit","price","cta","description","plan"];
const lines = [];
for (const locale of Object.keys(CARD_COPY)) {
  lines.push(`${JSON.stringify(locale)}:`);
  for (const key of KEYS) {
    const value = CARD_COPY[locale][key];
    if (typeof value !== "string" || !value) throw new Error(`${locale}.${key} is not a nonempty string`);
    lines.push(`  ${key}: ${JSON.stringify(value)}`);
  }
}
fs.writeFileSync("config/mobile_chat/card_copy.yml", lines.join("\n") + "\n");
console.log("wrote", Object.keys(CARD_COPY).length, "locales x", KEYS.length, "keys");
'
```

Expected: `wrote 41 locales x 10 keys`

- [ ] **Step 2: 静态校验生成的 YAML**

```bash
ruby -ryaml -e '
d = YAML.load_file("config/mobile_chat/card_copy.yml");
keys = %w[primary alternative data unlimited validity dayUnit price cta description plan];
raise "locales=#{d.size}" unless d.size == 41;
raise "en missing" unless d.key?("en");
raise "non-string keys: #{d.keys.reject { |k| k.is_a?(String) }.inspect}" unless d.keys.all? { |k| k.is_a?(String) };
raise "non-string values in #{d.keys.reject { |k| d[k].values.all? { |v| v.is_a?(String) } }.inspect}" unless d.values.all? { |copy| copy.values.all? { |v| v.is_a?(String) } };
bad = d.reject { |_, v| v.keys.sort == keys.sort };
raise "bad locales: #{bad.keys.inspect}" if bad.any?;
raise "zh_CN.primary=#{d["zh_CN"]["primary"]}" unless d["zh_CN"]["primary"] == "最佳匹配";
raise "en.validity=#{d["en"]["validity"]}" unless d["en"]["validity"] == "Validity";
raise "no.primary=#{d.dig("no", "primary").inspect}" unless d.dig("no", "primary") == "Beste treff";
puts "ok: #{d.size} locales, #{keys.size} keys each"
'
```

Expected: `ok: 41 locales, 10 keys each`

> `no` 这一条断言是防复发的：键一旦退回不加引号，Psych 会把它变成 `false`，`copy_for('no')` 静默回落英文，而"41 个 locale / 每个 10 键"的检查**照样通过**（实测踩过）。

- [ ] **Step 3: 写失败的 spec**（`bundle exec rspec` 需在有工具链的环境执行）

```ruby
require 'rails_helper'

RSpec.describe MobileChat::CardCopy do
  describe '.copy_for' do
    it 'returns the copy for an exact app locale' do
      expect(described_class.copy_for('zh_CN')['primary']).to eq('最佳匹配')
    end

    it 'returns the traditional copy for zh_Hant, not the simplified one' do
      expect(described_class.copy_for('zh_Hant')['primary']).to eq('最佳配對')
    end

    it 'falls back to the language prefix for a regional variant' do
      expect(described_class.copy_for('en_GB')['validity']).to eq('Validity')
    end

    it 'falls back to english for an unknown locale' do
      expect(described_class.copy_for('xx')).to eq(described_class.copy_for('en'))
    end

    it 'falls back to english when the locale is blank' do
      expect(described_class.copy_for(nil)).to eq(described_class.copy_for('en'))
    end

    it 'raises when the english dictionary is missing' do
      allow(described_class).to receive(:dictionaries).and_return({ 'zh_CN' => { 'primary' => '最佳匹配' } })

      expect { described_class.copy_for('fr') }.to raise_error(CustomExceptions::MobileChat::NotConfigured)
    end
  end

  describe '.sanitize_description' do
    let(:fallback) { described_class.copy_for('en')['description'] }

    it 'keeps plain text' do
      expect(described_class.sanitize_description('7 days in Japan, 10 GB.', fallback)).to eq('7 days in Japan, 10 GB.')
    end

    it 'collapses whitespace and drops control characters' do
      expect(described_class.sanitize_description("7 days\n\tin Japan", fallback)).to eq('7 days in Japan')
    end

    it 'falls back when the text carries a link' do
      expect(described_class.sanitize_description('See https://novyro.com/plan', fallback)).to eq(fallback)
    end

    it 'falls back when the text carries a bare domain' do
      expect(described_class.sanitize_description('Buy at novyro.com', fallback)).to eq(fallback)
    end

    it 'falls back when the text carries markdown' do
      expect(described_class.sanitize_description('- 7 days in Japan', fallback)).to eq(fallback)
      expect(described_class.sanitize_description('[plan](x)', fallback)).to eq(fallback)
    end

    it 'falls back when the text is longer than the limit' do
      expect(described_class.sanitize_description('a' * 501, fallback)).to eq(fallback)
    end

    it 'falls back when the text has more than one emoji' do
      expect(described_class.sanitize_description('🎌🇯🇵 plan', fallback)).to eq(fallback)
    end

    it 'falls back when the text is blank' do
      expect(described_class.sanitize_description('  ', fallback)).to eq(fallback)
      expect(described_class.sanitize_description(nil, fallback)).to eq(fallback)
    end
  end

  describe '.sanitize_action_text' do
    let(:fallback) { described_class.copy_for('en')['cta'] }

    it 'keeps a short label' do
      expect(described_class.sanitize_action_text('View plan', fallback)).to eq('View plan')
    end

    it 'falls back when the label is longer than the action text limit' do
      expect(described_class.sanitize_action_text('a' * 121, fallback)).to eq(fallback)
    end
  end
end
```

- [ ] **Step 4: 写实现**

```ruby
# frozen_string_literal: true

# Copy for the plan cards the mobile app renders natively.
#
# Deliberately not Chatwoot's I18n: these are business strings on a purchase surface, they are
# keyed by the client's own appLocale (zh_CN / zh_Hant / pt_BR ... -- a set the backend locale
# list does not match), and the cards are built inside a Captain job, which has no request locale
# to switch on. See docs/superpowers/specs/2026-10-08-mobile-chat-plan-cards-design.md section 4.
module MobileChat::CardCopy
  COPY_PATH = Rails.root.join('config/mobile_chat/card_copy.yml')
  # The end of the fallback chain: without it every lookup would hand back nil and fail far away.
  ENGLISH = 'en'
  # The message validator rejects a description over 500 and an action text over 120, so copy that
  # long must not reach the card builder.
  MAX_DESCRIPTION = 500
  MAX_ACTION_TEXT = 120
  MAX_EMOJI = 1
  # The card is a purchase surface: a link, markdown or a table in text the model wrote is
  # something the customer cannot trust. Fall back to the shipped copy instead.
  URL_LIKE = %r{(?:https?|ftp|file|ws|wss|mailto|tel|sms|data|javascript):|(?:\A|[^\w.-])www\.|\A\S*\.[a-z]{2,}(?:[/:?#]|\z)}i
  MARKDOWN_LIKE = %r{\]\(|^\s{0,3}\#{1,6}\s|^\s{0,3}(?:[-*+]\s|\d+[.)]\s)}i

  class << self
    # The bridge's chain (localeCopy.js): exact appLocale, then the language prefix, then en.
    def copy_for(locale)
      key = locale.to_s.strip
      dictionaries[key] || dictionaries[key.split('_').first] || dictionaries[ENGLISH] ||
        raise(CustomExceptions::MobileChat::NotConfigured, 'MOBILE_CHAT_CARD_COPY_EN')
    end

    def sanitize_description(value, fallback)
      sanitize(value, fallback, MAX_DESCRIPTION)
    end

    def sanitize_action_text(value, fallback)
      sanitize(value, fallback, MAX_ACTION_TEXT)
    end

    def dictionaries
      @dictionaries ||= YAML.load_file(COPY_PATH).freeze
    end

    private

    def sanitize(value, fallback, maximum)
      text = value.to_s.gsub(/[\u0000-\u001f\u007f-\u009f]/, ' ').squish
      return fallback if text.blank? || text.length > maximum
      return fallback if text.match?(URL_LIKE) || text.match?(MARKDOWN_LIKE)
      return fallback if text.scan(/\p{Extended_Pictographic}/).size > MAX_EMOJI

      text
    end
  end
end
```

- [ ] **Step 5: 静态检查（本机可跑）**

```bash
ruby -c app/services/mobile_chat/card_copy.rb && ruby -c spec/services/mobile_chat/card_copy_spec.rb
```

Expected: 两行 `Syntax OK`

- [ ] **Step 6: 跑 spec（需在有工具链的环境执行）**

```bash
bundle exec rspec spec/services/mobile_chat/card_copy_spec.rb
```

Expected: 16 examples, 0 failures

- [ ] **Step 7: Commit**

```bash
git add config/mobile_chat/card_copy.yml app/services/mobile_chat/card_copy.rb spec/services/mobile_chat/card_copy_spec.rb
git commit -m "feat(mobile-chat): ship the plan card copy for 41 app locales"
```

---

### Task 2: 校验器接受 novyro_plan_group

> **落地提示（实测）**：下面 Step 2 的代码照抄会踩 9 处 rubocop（`Metrics/CyclomaticComplexity` 13/7、`Metrics/AbcSize`、`Metrics/PerceivedComplexity`、`Style/IfUnlessModifier`），CI 会红。写之前先按 `.rubocop.yml` 拆方法（拆完注意 `Metrics/ClassLength` Max 175，很容易顶到）。另外 `compatible_hash_keys?(item, REQUIRED, REQUIRED)` 传的是同一个常量两遍，等价于 `exact_hash_keys?`，直接用它、别加那个助手。

**Files:**
- Modify: `app/models/concerns/content_attribute_validator.rb`
- Test: `spec/models/concerns/content_attribute_validator_spec.rb`（新增）

**Interfaces:**
- Consumes: 无（只看消息自身）
- Produces: `Message` 接受 `content_type: :cards` + `content_attributes: { "variant" => "novyro_plan_group", "items" => [...] }`；其余变体仍走原白名单路径

- [ ] **Step 1: 写失败的 spec**

```ruby
require 'rails_helper'

RSpec.describe ContentAttributeValidator do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:card) do
    {
      title: 'Japan',
      description: 'Verified plan option.',
      media_url: '',
      badge: 'Best match',
      facts: [
        { icon: 'wifi', label: 'Data', value: '10 GB' },
        { icon: 'calendar', label: 'Validity', value: '7 days' },
        { icon: 'wallet', label: 'Price', value: 'USD 16.99' }
      ],
      actions: [{
        type: 'link',
        text: 'View plan',
        uri: 'https://support.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod'
      }]
    }
  end
  let(:items) { [card] }
  let(:message) do
    build(:message, account: account, inbox: inbox, conversation: conversation,
                    content_type: :cards, content: 'Japan',
                    content_attributes: { variant: 'novyro_plan_group', items: items })
  end

  # `let` has no setter, so an example that needs different items rebuilds the attribute hash.
  def plan_group(items)
    { variant: 'novyro_plan_group', items: items }
  end

  it 'accepts a plan group card' do
    expect(message).to be_valid
  end

  it 'accepts up to five items' do
    message.content_attributes = plan_group(Array.new(5) { card })

    expect(message).to be_valid
  end

  it 'rejects an unknown top level key' do
    message.content_attributes = plan_group(items).merge(extra: 1)

    expect(message).not_to be_valid
  end

  it 'rejects a missing variant' do
    message.content_attributes = { items: items }

    expect(message).not_to be_valid
  end

  it 'rejects more than five items' do
    message.content_attributes = plan_group(Array.new(6) { card })

    expect(message).not_to be_valid
  end

  it 'rejects an item without a badge' do
    message.content_attributes = plan_group([card.except(:badge)])

    expect(message).not_to be_valid
  end

  it 'rejects an item without facts' do
    message.content_attributes = plan_group([card.except(:facts)])

    expect(message).not_to be_valid
  end

  it 'rejects a nonempty media_url' do
    message.content_attributes = plan_group([card.merge(media_url: 'https://cdn.example.com/jp.svg')])

    expect(message).not_to be_valid
  end

  it 'rejects an unknown fact icon' do
    message.content_attributes = plan_group([card.merge(facts: [{ icon: 'star', label: 'Data', value: '10 GB' }])])

    expect(message).not_to be_valid
  end

  it 'rejects more than three facts' do
    facts = card[:facts] + [{ icon: 'wifi', label: 'Extra', value: 'x' }]
    message.content_attributes = plan_group([card.merge(facts: facts)])

    expect(message).not_to be_valid
  end

  it 'rejects an empty fact list' do
    message.content_attributes = plan_group([card.merge(facts: [])])

    expect(message).not_to be_valid
  end

  it 'rejects an item with two actions' do
    message.content_attributes = plan_group([card.merge(actions: card[:actions] + card[:actions])])

    expect(message).not_to be_valid
  end

  it 'rejects a postback action' do
    action = card[:actions].first.merge(type: 'postback')
    message.content_attributes = plan_group([card.merge(actions: [action])])

    expect(message).not_to be_valid
  end

  it 'rejects a checkout uri without the catalog environment' do
    action = card[:actions].first.merge(uri: 'https://support.example.com/app-actions/checkout?goods_id=13&sku_id=13055')
    message.content_attributes = plan_group([card.merge(actions: [action])])

    expect(message).not_to be_valid
  end

  it 'rejects a checkout uri on another path' do
    action = card[:actions].first.merge(uri: 'https://support.example.com/checkout?goods_id=13&sku_id=13055&catalog_env=prod')
    message.content_attributes = plan_group([card.merge(actions: [action])])

    expect(message).not_to be_valid
  end

  it 'rejects an unknown catalog environment' do
    action = card[:actions].first.merge(uri: 'https://support.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=staging')
    message.content_attributes = plan_group([card.merge(actions: [action])])

    expect(message).not_to be_valid
  end

  it 'rejects an oversized title' do
    message.content_attributes = plan_group([card.merge(title: 'a' * 161)])

    expect(message).not_to be_valid
  end

  it 'rejects control characters in a fact value' do
    message.content_attributes = plan_group([card.merge(facts: [{ icon: 'wifi', label: 'Data', value: "10\u0000GB" }])])

    expect(message).not_to be_valid
  end

  it 'still rejects unknown keys on a plain card' do
    message.content_attributes = { items: [card] }

    expect(message).not_to be_valid
  end
end
```

> `plan_group` 是个 3 行的局部构造器，只为让每个例子只写"这份 items 和默认有什么不同"；若 reviewer 认为它属于"spec 里的自定义 helper"，就把它内联展开成 `{ variant: 'novyro_plan_group', items: [...] }`（多打 20 遍）。

- [ ] **Step 2: 写实现**（在 `app/models/concerns/content_attribute_validator.rb` 里加常量与分支；`validate` 的 `when 'cards'` 改成先判断变体）

常量加在 `ALLOWED_ARTICLE_KEYS` 之后：

```ruby
  # The plan cards the mobile app renders natively. This variant is its own contract: the app
  # reads badge and facts and builds the checkout URL from the action's query terms, so a card
  # outside this shape renders wrong or offers a dead button -- reject at write time instead.
  NOVYRO_PLAN_VARIANT = 'novyro_plan_group'.freeze
  NOVYRO_PLAN_TOP_LEVEL_KEYS = [:variant, :items].freeze
  NOVYRO_PLAN_REQUIRED_ITEM_KEYS = [:title, :description, :media_url, :badge, :facts, :actions].freeze
  NOVYRO_PLAN_MAX_ITEMS = 5
  NOVYRO_PLAN_MAX_FACTS = 3
  NOVYRO_PLAN_FACT_KEYS = [:icon, :label, :value].freeze
  NOVYRO_PLAN_FACT_ICONS = %w[wifi calendar wallet].freeze
  NOVYRO_PLAN_ACTION_KEYS = [:type, :text, :uri].freeze
  NOVYRO_PLAN_ACTION_PATH = '/app-actions/checkout'.freeze
  NOVYRO_PLAN_ACTION_QUERY_KEYS = %w[catalog_env goods_id sku_id].freeze
  NOVYRO_PLAN_CATALOG_ENVIRONMENTS = %w[dev test prod].freeze
  NOVYRO_PLAN_MAX_SAFE_ID = 9_007_199_254_740_991
  NOVYRO_PLAN_TEXT_LIMITS = {
    title: 160, description: 500, badge: 40,
    fact_label: 40, fact_value: 120, action_text: 120, action_uri: 2048
  }.freeze
```

`validate` 的 `when 'cards'`：

```ruby
    when 'cards'
      if novyro_plan_group?(record)
        validate_novyro_plan_group!(record)
      else
        validate_items!(record)
        validate_item_attributes!(record, ALLOWED_CARD_ITEM_KEYS)
        validate_item_actions!(record)
      end
```

`private` 区新增（放在 `validate_items!` 之前）：

```ruby
  def novyro_plan_group?(record)
    attribute_value(record.content_attributes, :variant) == NOVYRO_PLAN_VARIANT
  end

  def validate_novyro_plan_group!(record)
    unless exact_hash_keys?(record.content_attributes, NOVYRO_PLAN_TOP_LEVEL_KEYS)
      record.errors.add(:content_attributes, 'contains invalid keys for Novyro plan group')
    end

    items = record.items
    unless items.is_a?(Array)
      record.errors.add(:content_attributes, 'Items should be an array.')
      return
    end

    if items.empty? || items.length > NOVYRO_PLAN_MAX_ITEMS
      record.errors.add(:content_attributes, 'Novyro plan group must contain one to five items.')
    end

    items.each { |item| validate_novyro_plan_item!(record, item) }
  end

  def validate_novyro_plan_item!(record, item)
    return record.errors.add(:content_attributes, 'Novyro plan items must be hashes.') unless item.is_a?(Hash)

    unless compatible_hash_keys?(item, NOVYRO_PLAN_REQUIRED_ITEM_KEYS, NOVYRO_PLAN_REQUIRED_ITEM_KEYS)
      record.errors.add(:content_attributes, 'contains invalid keys for Novyro plan items')
    end

    NOVYRO_PLAN_TEXT_LIMITS.slice(:title, :description, :badge).each do |key, maximum|
      validate_bounded_text!(record, item, key, maximum)
    end

    unless attribute_value(item, :media_url) == ''
      record.errors.add(:content_attributes, 'Novyro plan media_url must be empty.')
    end

    validate_novyro_plan_facts!(record, attribute_value(item, :facts))
    validate_novyro_plan_actions!(record, attribute_value(item, :actions))
  end

  def validate_novyro_plan_facts!(record, facts)
    unless facts.is_a?(Array) && facts.length.between?(1, NOVYRO_PLAN_MAX_FACTS)
      record.errors.add(:content_attributes, 'Novyro plan facts must contain one to three items.')
      return
    end

    facts.each do |fact|
      unless exact_hash_keys?(fact, NOVYRO_PLAN_FACT_KEYS)
        record.errors.add(:content_attributes, 'contains invalid keys for Novyro plan facts')
        next unless fact.is_a?(Hash)
      end

      unless NOVYRO_PLAN_FACT_ICONS.include?(attribute_value(fact, :icon))
        record.errors.add(:content_attributes, 'contains invalid Novyro plan fact icon')
      end
      validate_bounded_text!(record, fact, :label, NOVYRO_PLAN_TEXT_LIMITS[:fact_label])
      validate_bounded_text!(record, fact, :value, NOVYRO_PLAN_TEXT_LIMITS[:fact_value])
    end
  end

  def validate_novyro_plan_actions!(record, actions)
    unless actions.is_a?(Array) && actions.length == 1 && actions.first.is_a?(Hash)
      record.errors.add(:content_attributes, 'Novyro plan items require exactly one action.')
      return
    end

    action = actions.first
    unless exact_hash_keys?(action, NOVYRO_PLAN_ACTION_KEYS)
      record.errors.add(:content_attributes, 'contains invalid keys for Novyro plan actions')
    end
    unless attribute_value(action, :type) == 'link'
      record.errors.add(:content_attributes, 'Novyro plan action type must be link.')
    end
    validate_bounded_text!(record, action, :text, NOVYRO_PLAN_TEXT_LIMITS[:action_text])
    validate_bounded_text!(record, action, :uri, NOVYRO_PLAN_TEXT_LIMITS[:action_uri])

    uri = attribute_value(action, :uri)
    return unless valid_nonempty_text?(uri, NOVYRO_PLAN_TEXT_LIMITS[:action_uri])

    record.errors.add(:content_attributes, 'Novyro plan action uri is invalid.') unless checkout_uri?(uri)
  end

  # The app opens its own checkout from exactly these three terms; a fourth term or a missing one
  # is a link the customer cannot complete a purchase with.
  def checkout_uri?(value)
    uri = URI.parse(value)
    return false unless uri.is_a?(URI::HTTP) && %w[http https].include?(uri.scheme) &&
                        uri.host.present? && uri.userinfo.nil? && uri.fragment.nil? &&
                        uri.path == NOVYRO_PLAN_ACTION_PATH

    pairs = URI.decode_www_form(uri.query.to_s)
    return false unless pairs.length == NOVYRO_PLAN_ACTION_QUERY_KEYS.length &&
                        pairs.map(&:first).sort == NOVYRO_PLAN_ACTION_QUERY_KEYS

    terms = pairs.to_h
    checkout_id?(terms['goods_id']) && checkout_id?(terms['sku_id']) &&
      NOVYRO_PLAN_CATALOG_ENVIRONMENTS.include?(terms['catalog_env'])
  rescue URI::InvalidURIError, ArgumentError
    false
  end

  def checkout_id?(value)
    value.is_a?(String) && value.match?(/\A[0-9]+\z/) &&
      value.to_i.between?(1, NOVYRO_PLAN_MAX_SAFE_ID)
  end

  def validate_bounded_text!(record, attributes, key, maximum)
    return if valid_nonempty_text?(attribute_value(attributes, key), maximum)

    record.errors.add(:content_attributes, "Novyro plan #{key} must be a nonempty string of at most #{maximum} characters.")
  end

  def valid_nonempty_text?(value, maximum = nil)
    value.is_a?(String) && value.strip.present? &&
      (maximum.nil? || value.length <= maximum) &&
      !value.match?(/[\u0000-\u001f\u007f-\u009f]/)
  end

  def exact_hash_keys?(value, expected_keys)
    return false unless value.is_a?(Hash) && value.keys.length == expected_keys.length

    normalized = value.keys.map { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
    normalized.all? { |key| expected_keys.include?(key) } &&
      expected_keys.all? { |key| normalized.include?(key) }
  end

  def compatible_hash_keys?(value, required_keys, allowed_keys)
    return false unless value.is_a?(Hash)

    normalized = value.keys.map { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
    normalized.length == normalized.uniq.length &&
      normalized.all? { |key| allowed_keys.include?(key) } &&
      required_keys.all? { |key| normalized.include?(key) }
  end

  def attribute_value(attributes, key)
    return unless attributes.is_a?(Hash)

    attributes.key?(key) ? attributes[key] : attributes[key.to_s]
  end
```

文件顶部加 `require 'uri'`。

- [ ] **Step 3: 静态检查（本机可跑）**

```bash
ruby -c app/models/concerns/content_attribute_validator.rb && ruby -c spec/models/concerns/content_attribute_validator_spec.rb
```

Expected: 两行 `Syntax OK`

- [ ] **Step 4: 跑 spec（需在有工具链的环境执行）**

```bash
bundle exec rspec spec/models/concerns/content_attribute_validator_spec.rb spec/controllers/api/v1/accounts/conversations/messages_controller_spec.rb
```

Expected: 新增 19 examples 全过；既有 cards/input_select 用例不受影响（普通卡片仍走白名单路径）

- [ ] **Step 5: Commit**

```bash
git add app/models/concerns/content_attribute_validator.rb spec/models/concerns/content_attribute_validator_spec.rb
git commit -m "feat(mobile-chat): validate the novyro plan group card contract"
```

---

### Task 3: toolkit 组卡与上游语言/币种

**Files:**
- Modify: `app/services/mobile_chat/captain_toolkit.rb`
- Test: `spec/services/mobile_chat/captain_toolkit_spec.rb`（改）

**Interfaces:**
- Consumes: `MobileChat::CardCopy.copy_for` / `.sanitize_description` / `.sanitize_action_text`（Task 1）
- Produces:
  - `MobileChat::CaptainToolkit#purchase_actions(params) → { ok: true, cards: [card] } | { ok: false, error: String }`，card 是可直接进 `post_cards` 的 item Hash（`title/description/media_url/badge/facts/actions`）
  - `MobileChat::CaptainToolkit#fetch_catalog_json(path, query:)`（内部走 `fetch_json(..., headers:)`，带上 `lang` / `currency`）

> **位置很关键**：`purchase_actions` 必须放在类里**第一个 `private` 之前**（现在 `plan_cards` 就在那个位置），否则工具调不到它；新的私有助手放进已有的 `# --- Card building ---` 段落（那段本来就在 private 区，不要再写一个 `private`）。

- [ ] **Step 1: 写失败的 spec**（把 `spec/services/mobile_chat/captain_toolkit_spec.rb` 里 `describe '#plan_cards'` 整段替换；`#recommend_plans` 段保留并补一条 header 断言）

```ruby
  describe '#recommend_plans' do
    it 'sends the customer language and currency upstream' do
      contact.update!(custom_attributes: contact.custom_attributes.merge('locale' => 'zh_CN', 'currency' => 'CNY'))
      stub_request(:get, recommendations_url)
        .with(query: { country_code: 'JP', billing_period: '7' },
              headers: { 'lang' => 'zh_CN', 'currency' => 'CNY' })
        .to_return(status: 200, body: { code: 1, data: { recommendations: [] } }.to_json)

      expect(described_class.new(conversation).recommend_plans({ country_code: 'JP', billing_period: 7 })[:ok]).to be(true)
    end
  end

  describe '#purchase_actions' do
    let(:product_details_url) { 'https://api.example.com/api/v2/esim/product/details' }
    # The test env has no FRONTEND_URL, and the checkout uri is built from it; the repo helper is
    # the sanctioned way to set env in specs.
    around do |example|
      with_modified_env(FRONTEND_URL: 'https://app.example.com') { example.run }
    end
    let(:contact) do
      create(:contact, account: account, identifier: 'member_12345',
                       custom_attributes: { 'app_token' => 'member-token', 'locale' => 'zh_CN',
                                            'currency' => 'USD', 'catalog_environment' => 'prod' })
    end
    let(:params) { { 'product_id' => '13', 'sku_ids' => %w[13055 13056], 'reason' => '7天日本专属行程，10GB总量。', 'label' => '日本 7日 10GB 总量套餐' } }

    before do
      stub_request(:get, product_details_url)
        .with(query: { product_id: '13' }, headers: { 'lang' => 'zh_CN', 'currency' => 'USD' })
        .to_return(
          status: 200,
          body: {
            code: 1,
            data: {
              product_id: 13,
              name: '日本',
              country_code: 'JP',
              country_image: 'https://cdn/JP.svg',
              skus: [
                { id: 13055, data_size_gb: '10', billing_period_days: 7, price: { 'USD' => '16.99' } },
                { id: 13056, data_size_gb: '0', data_size_is_unlimited: true, billing_period_days: 7, price: { 'USD' => '35.99' } }
              ]
            }
          }.to_json
        )
    end

    it 'builds one card per sku, primary first, with the copy for the customer locale' do
      result = toolkit.purchase_actions(params)

      expect(result[:ok]).to be(true)
      primary, alternative = result[:cards]
      expect(primary[:title]).to eq('日本')
      expect(primary[:badge]).to eq('最佳匹配')
      expect(primary[:description]).to eq('7天日本专属行程，10GB总量。')
      expect(primary[:media_url]).to eq('')
      expect(alternative[:badge]).to eq('备选方案')
      expect(alternative[:description]).to eq('已核实套餐方案。')
    end

    it 'takes facts from the upstream sku' do
      facts = toolkit.purchase_actions(params)[:cards].first[:facts]

      expect(facts).to eq(
        [
          { icon: 'wifi', label: '流量', value: '10 GB' },
          { icon: 'calendar', label: '有效期', value: '7天' },
          { icon: 'wallet', label: '价格', value: 'USD 16.99' }
        ]
      )
    end

    it 'labels an unlimited sku with the copied wording' do
      facts = toolkit.purchase_actions(params)[:cards].last[:facts]

      expect(facts.first).to eq(icon: 'wifi', label: '流量', value: '无限流量')
    end

    it 'builds the checkout uri from the frontend url and the recorded catalog environment' do
      action = toolkit.purchase_actions(params)[:cards].first[:actions].first

      expect(action[:type]).to eq('link')
      expect(action[:text]).to eq('日本 7日 10GB 总量套餐')
      expect(action[:uri]).to eq('https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod')
    end

    it 'falls back to the shipped copy when the model text carries a link' do
      result = toolkit.purchase_actions(params.merge('reason' => 'see https://novyro.com'))

      expect(result[:cards].first[:description]).to eq('已核实套餐方案。')
    end

    it 'refuses a sku that is not in the product' do
      result = toolkit.purchase_actions(params.merge('sku_ids' => %w[13055 99999]))

      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'refuses ids that are not numeric' do
      result = toolkit.purchase_actions(params.merge('sku_ids' => ['../etc']))

      expect(result[:ok]).to be(false)
    end

    it 'takes at most five skus' do
      result = toolkit.purchase_actions(params.merge('sku_ids' => Array.new(6) { '13055' }))

      expect(result[:cards].size).to eq(5)
    end

    it 'refuses an empty sku list' do
      expect(toolkit.purchase_actions(params.merge('sku_ids' => []))[:ok]).to be(false)
    end
  end
```

既有 `before` 块里的 installation_config 不用改（`NOVYRO_*` 那三条已在）。`#purchase_actions` 里用 `around` + `with_modified_env` 提供 `FRONTEND_URL`，所以断言的 uri 就是 `https://app.example.com/app-actions/checkout?...`；`#recommend_plans` 那条新用例不碰 FRONTEND_URL，放在外层 describe 即可。

- [ ] **Step 2: 写实现**（`app/services/mobile_chat/captain_toolkit.rb`）

`fetch_json` 增加 `headers:` 参数，并新增 `fetch_catalog_json`：

```ruby
  def fetch_json(path, query: {}, token: nil, headers: {})
    url = MobileChat::Config.novyro_url(path)
    url = "#{url}?#{URI.encode_www_form(query)}" if query.present?

    request_headers = MobileChat::Config.novyro_headers.merge(headers)
    request_headers['token'] = token if token.present?
    # …以下原样保留（SafeFetch / 状态码判定）
  end

  # Product reads carry the customer's language and currency as headers, which is how upstream
  # decides the copy and the price it answers with (the bridge did the same via publicHeaders).
  # Orders are read with the member token and keep the plain service headers.
  def fetch_catalog_json(path, query: {})
    fetch_json(path, query: query, headers: { 'lang' => client_locale, 'currency' => client_currency })
  end
```

把 `recommend_plans` / `search_products` / `get_product_details` 里的 `fetch_json(...)` 换成 `fetch_catalog_json(...)`。

新增（**替换现有的 `plan_cards`，位置保持在第一个 `private` 之前**）：

```ruby
  # The model decides which SKUs to recommend; the numbers, the copy and the checkout link come
  # from here. One call posts one message: order is rank, because the app renders the first item
  # as the main card and the rest as alternatives.
  def purchase_actions(params)
    product_id = param(params, :product_id).to_s
    sku_ids = Array(param(params, :sku_ids)).map(&:to_s).first(CARD_LIMIT)
    return { ok: false, error: 'product_id and one to five sku_ids are required.' } if product_id.blank? || sku_ids.empty?
    return { ok: false, error: 'product_id and sku_ids must be numeric ids.' } unless [product_id, *sku_ids].all? { |id| checkout_id?(id) }

    response = fetch_catalog_json(PRODUCT_DETAILS_PATH, query: { product_id: product_id })
    return response if response[:ok] == false

    product = present_product(response.dig(:data, 'product') || response[:data], product_id)
    skus = sku_ids.map { |id| Array(product[:skus]).find { |sku| sku[:sku_id].to_s == id } }
    return { ok: false, error: 'Those sku_ids are not part of that product.' } if skus.any?(&:nil?)

    copy = MobileChat::CardCopy.copy_for(client_locale)
    cards = skus.each_with_index.map do |sku, index|
      purchase_card(product, sku, copy, primary: index.zero?, reason: param(params, :reason), label: param(params, :label))
    end
    { ok: true, cards: cards }
  end
```

并把 `# --- Card building ---` 段落里原有的 `plan_card` / `from_price_label` / `sku_label` / `price_label` / `sku_action` 整体替换成下面这些私有助手：

```ruby
  def purchase_card(product, sku, copy, primary:, reason:, label:)
    {
      title: product[:name].to_s,
      description: MobileChat::CardCopy.sanitize_description(primary ? reason : nil, copy['description']),
      media_url: '',
      badge: primary ? copy['primary'] : copy['alternative'],
      facts: purchase_facts(sku, copy),
      actions: [{
        type: 'link',
        text: MobileChat::CardCopy.sanitize_action_text(primary ? label : nil, copy['cta']),
        uri: checkout_uri(product[:product_id], sku[:sku_id])
      }]
    }
  end

  def purchase_facts(sku, copy)
    [
      { icon: 'wifi', label: copy['data'], value: data_fact_value(sku, copy) },
      { icon: 'calendar', label: copy['validity'], value: validity_fact_value(sku, copy) },
      { icon: 'wallet', label: copy['price'], value: price_fact_value(sku, client_currency) }
    ].select { |fact| fact[:value].present? }
  end

  def data_fact_value(sku, copy)
    return copy['unlimited'] if sku[:data_unlimited]

    [sku[:data_size_value], sku[:data_size_unit]].compact.join(' ').presence
  end

  def validity_fact_value(sku, copy)
    days = sku[:billing_period_days]
    return if days.blank?

    copy['dayUnit'].sub('{n}', days.to_s)
  end

  # Upstream prices are a map of currency to amount. Ask for the customer's currency, but label
  # whatever we end up showing with the currency it actually is.
  def price_fact_value(sku, currency)
    prices = hash(sku[:price])
    key = prices.key?(currency) ? currency : prices.keys.first
    return if key.blank?

    "#{key} #{format('%.2f', prices[key].to_f)}"
  end

  # The app opens its own checkout from this path; the website handles the click itself. All three
  # query terms are required by the message validator, so a missing catalog environment has to
  # come from deployment config rather than be dropped.
  def checkout_uri(product_id, sku_id)
    query = URI.encode_www_form(goods_id: product_id, sku_id: sku_id, catalog_env: catalog_environment)
    "#{MobileChat::Config.frontend_url}/app-actions/checkout?#{query}"
  end

  def catalog_environment
    contact&.custom_attributes&.dig('catalog_environment').presence ||
      MobileChat::Config.value('NOVYRO_CATALOG_ENVIRONMENT')
  end

  def checkout_id?(value)
    value.match?(/\A[1-9][0-9]{0,18}\z/)
  end

  # The clients send these on every session; upstream rejects a malformed value, and a cosmetic
  # client bug must not be able to take plan lookup down, so fall back to the documented defaults.
  def client_locale
    value = contact&.custom_attributes&.dig('locale').to_s
    value.match?(/\A[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*\z/) ? value : 'en'
  end

  def client_currency
    value = contact&.custom_attributes&.dig('currency').to_s.upcase
    value.match?(/\A[A-Z]{3}\z/) ? value : 'USD'
  end
```

`CARD_LIMIT` 从 5 沿用（去掉 `CARD_ACTION_LIMIT`，不再需要）。

- [ ] **Step 3: 静态检查（本机可跑）**

```bash
ruby -c app/services/mobile_chat/captain_toolkit.rb && ruby -c spec/services/mobile_chat/captain_toolkit_spec.rb
grep -n "plan_cards\|sku_action\|from_price_label\|CARD_ACTION_LIMIT" app/services/mobile_chat/captain_toolkit.rb
```

Expected: 两行 `Syntax OK`；grep 无输出（旧路径已删净）

- [ ] **Step 4: 跑 spec（需在有工具链的环境执行）**

```bash
bundle exec rspec spec/services/mobile_chat/captain_toolkit_spec.rb
```

Expected: 全过；`#recommend_plans` / `#search_products` / `#get_product_details` 既有用例不受影响

- [ ] **Step 5: Commit**

```bash
git add app/services/mobile_chat/captain_toolkit.rb spec/services/mobile_chat/captain_toolkit_spec.rb
git commit -m "feat(mobile-chat): build plan cards from the upstream sku, not the model"
```

---

### Task 4: 两个工具与消息投递

**Files:**
- Modify: `enterprise/lib/captain/tools/mobile_chat_tool.rb`
- Modify: `enterprise/lib/captain/tools/recommend_plan_tool.rb`
- Create: `enterprise/lib/captain/tools/create_purchase_action_tool.rb`
- Modify: `config/agents/tools.yml`
- Test: `spec/enterprise/lib/captain/tools/create_purchase_action_tool_spec.rb`（新增）

**Interfaces:**
- Consumes: `MobileChat::CaptainToolkit#purchase_actions`（Task 3）
- Produces:
  - `Captain::Tools::CreatePurchaseActionTool`（参数 `product_id` / `sku_ids` / `reason` / `label`）
  - `Captain::Tools::MobileChatTool#post_cards(tool_context, cards) → Boolean`（发 `variant: 'novyro_plan_group'`）
  - `Captain::Tools::RecommendPlanTool` 只回 JSON

- [ ] **Step 1: 写失败的 spec**

```ruby
require 'rails_helper'

RSpec.describe Captain::Tools::CreatePurchaseActionTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) do
    create(:contact, account: account, identifier: 'member_12345',
                     custom_attributes: { 'app_token' => 'member-token', 'locale' => 'en',
                                          'currency' => 'USD', 'catalog_environment' => 'prod' })
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:tool) { described_class.new(assistant) }
  # The repo's tool specs build the context as a bare Struct (see handoff_tool_spec.rb).
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id } }) }
  let(:toolkit) { instance_double(MobileChat::CaptainToolkit) }
  let(:cards) do
    [{
      title: 'Japan', description: 'Verified plan option.', media_url: '', badge: 'Best match',
      facts: [{ icon: 'wifi', label: 'Data', value: '10 GB' }],
      actions: [{ type: 'link', text: 'View plan',
                  uri: 'https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod' }]
    }]
  end

  before { allow(MobileChat::CaptainToolkit).to receive(:new).and_return(toolkit) }

  it 'posts the cards as a novyro plan group message' do
    allow(toolkit).to receive(:purchase_actions).and_return({ ok: true, cards: cards })

    result = tool.perform(tool_context, product_id: '13', sku_ids: %w[13055], reason: 'x', label: 'y')

    message = conversation.messages.last
    expect(message.content_type).to eq('cards')
    expect(message.content).to eq('Japan')
    expect(message.content_attributes['variant']).to eq('novyro_plan_group')
    # content_attributes is a jsonb-backed store: symbol keys come back as strings.
    expect(message.content_attributes['items']).to eq(cards.deep_stringify_keys)
    expect(result).to include('Posted 1 plan card')
  end

  it 'returns the toolkit error instead of posting when the skus do not check out' do
    allow(toolkit).to receive(:purchase_actions).and_return({ ok: false, error: 'Those sku_ids are not part of that product.' })

    result = tool.perform(tool_context, product_id: '13', sku_ids: %w[99999], reason: 'x', label: 'y')

    expect(result).to include('not part of that product')
    expect(conversation.messages.count).to eq(0)
  end
end
```

- [ ] **Step 2: 改 `post_cards`**

```ruby
  # Cards render natively in the widget and in the app, but they need a conversation to live in.
  # The Playground has none, so a tool that cannot post still returns its JSON for the model.
  #
  # The variant is the app's contract: it tells the app which item keys to expect. Without it the
  # message validates as a plain card and the app has nothing to render a plan from.
  def post_cards(tool_context, cards)
    return false if cards.blank?

    conversation = find_conversation(tool_context.state)
    return false if conversation.blank?

    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      # Captain's own replies are sent by the assistant record, and that sender is what the widget
      # shows as the agent name. Without it the card renders under the widget's "Bot" fallback,
      # so one reply would look like two different senders.
      sender: @assistant,
      content_type: :cards,
      # The widget only renders an agent bubble when the message has content
      # (AgentMessage#shouldDisplayAgentMessage returns message.content), so a content-less
      # cards message is created correctly and then never shown.
      content: cards.map { |card| card[:title] }.join(' · '),
      content_attributes: { variant: 'novyro_plan_group', items: cards }
    )
    true
  end
```

- [ ] **Step 3: 新增工具类**

```ruby
# Records the plan the model decided to recommend and posts it as cards. The model only chooses
# which SKUs; prices, data, validity and the checkout link come from the catalogue on this call,
# so a hallucinated number cannot reach a customer's purchase surface.
class Captain::Tools::CreatePurchaseActionTool < Captain::Tools::MobileChatTool
  description 'Post the recommended plan as cards. Call this in the same turn you first mention a ' \
              'concrete plan, using sku ids from this turn\'s recommend_plans result, with the most ' \
              'recommended sku first.'
  parameter :product_id, type: 'string', description: 'Product id from recommend_plans, e.g. 13', required: true
  parameter :sku_ids, type: 'array', description: 'Sku ids from recommend_plans, most recommended first, at most 5', required: true
  parameter :reason, type: 'string', description: 'One sentence, in the customer\'s language, saying why the first sku fits their trip', required: true
  parameter :label, type: 'string', description: 'Button text for the first card, in the customer\'s language, e.g. Japan 7 days 10GB', required: true

  def perform(tool_context, **params)
    result = toolkit(tool_context).purchase_actions(params)
    return result[:error] if result[:ok] == false
    return result.to_json unless post_cards(tool_context, result[:cards])

    "Posted #{result[:cards].size} plan cards to the customer. Their buttons carry the purchase " \
      'action, so refer to the cards instead of repeating the prices in your reply.'
  end
end
```

- [ ] **Step 4: `recommend_plans` 只回数据**

```ruby
class Captain::Tools::RecommendPlanTool < Captain::Tools::MobileChatTool
  description 'Recommend eSIM plans for a destination and trip length, with prices and sku ids. ' \
              'Call this before recommending a plan, then create_purchase_action with the sku ids.'
  parameter :country_code, type: 'string', description: 'ISO 3166-1 alpha-2 destination code, e.g. JP', required: true
  parameter :billing_period, type: 'integer', description: 'Trip length in days, e.g. 7', required: true

  def perform(tool_context, **params)
    toolkit(tool_context).recommend_plans(params).to_json
  end
end
```

- [ ] **Step 5: 注册工具**

`config/agents/tools.yml` 末尾追加：

```yaml
- id: create_purchase_action
  title: 'Create Purchase Action'
  description: 'Post the recommended plan as cards with a working checkout button'
  icon: 'checkmark'
```

- [ ] **Step 6: 静态检查（本机可跑）**

```bash
ruby -c enterprise/lib/captain/tools/create_purchase_action_tool.rb \
  && ruby -c enterprise/lib/captain/tools/recommend_plan_tool.rb \
  && ruby -c enterprise/lib/captain/tools/mobile_chat_tool.rb \
  && ruby -ryaml -e 'y=YAML.load_file("config/agents/tools.yml"); raise unless y.any? { |t| t["id"] == "create_purchase_action" }; puts "ok: #{y.size} tools"'
```

Expected: `Syntax OK` ×3 + `ok: N tools`

- [ ] **Step 7: 跑 spec（需在有工具链的环境执行）**

```bash
bundle exec rspec spec/enterprise/lib/captain/tools/create_purchase_action_tool_spec.rb
```

Expected: 2 examples, 0 failures

- [ ] **Step 8: Commit**

```bash
git add enterprise/lib/captain/tools/mobile_chat_tool.rb enterprise/lib/captain/tools/recommend_plan_tool.rb \
        enterprise/lib/captain/tools/create_purchase_action_tool.rb config/agents/tools.yml \
        spec/enterprise/lib/captain/tools/create_purchase_action_tool_spec.rb
git commit -m "feat(mobile-chat): post plan cards from a create_purchase_action tool"
```

---

### Task 5: 契约对照与实例验收

**Files:**
- Test: `spec/services/mobile_chat/plan_card_contract_spec.rb`（新增）

**Interfaces:**
- Consumes: Task 2 的校验器 + Task 3 的 `purchase_actions`
- Produces: 一条把 App 冻结样本喂进校验器的 spec（本仓库唯一能自动证明"契约一致"的东西）

- [ ] **Step 1: 写 spec**（样本逐字取自 `esimgo-mobile/test/chatwoot_client_models_test.dart:248` 那条 "complete Novyro plan-group response contract"）

```ruby
require 'rails_helper'

# The app's contract sample, verbatim from
# esimgo-mobile/test/chatwoot_client_models_test.dart ("parses the complete Novyro plan-group
# response contract"). If this stops validating, the app stops rendering plan cards.
RSpec.describe 'novyro plan group contract' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) do
    build(:message, account: account, inbox: inbox, conversation: conversation,
                    content_type: :cards, content: '久等了。您的 eSIM 在这里。',
                    content_attributes: {
                      'variant' => 'novyro_plan_group',
                      'items' => [{
                        'title' => 'Japan',
                        'description' => '7天日本专属行程，10GB总量。',
                        'media_url' => '',
                        'badge' => '最佳匹配',
                        'facts' => [
                          { 'icon' => 'wifi', 'label' => '流量', 'value' => '10 GB' },
                          { 'icon' => 'calendar', 'label' => '有效期', 'value' => '7 天' },
                          { 'icon' => 'wallet', 'label' => '价格', 'value' => 'USD 16.99' }
                        ],
                        'actions' => [{
                          'type' => 'link',
                          'text' => '日本 7日 10GB 总量套餐',
                          'uri' => 'https://support-api.esingo.app/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod'
                        }]
                      }]
                    })
  end

  it 'accepts the sample the app parses' do
    expect(message).to be_valid
  end
end
```

- [ ] **Step 2: 静态检查（本机可跑）**

```bash
ruby -c spec/services/mobile_chat/plan_card_contract_spec.rb
```

Expected: `Syntax OK`

- [ ] **Step 3: 跑本任务与全部相关 spec（需在有工具链的环境执行）**

```bash
bundle exec rspec spec/services/mobile_chat spec/models/concerns/content_attribute_validator_spec.rb \
  spec/enterprise/lib/captain/tools/create_purchase_action_tool_spec.rb
```

Expected: 全过

- [ ] **Step 4: Commit**

```bash
git add spec/services/mobile_chat/plan_card_contract_spec.rb
git commit -m "test(mobile-chat): pin the plan card contract to the app's sample"
```

- [ ] **Step 5: 真实会话验收（部署后做，见 Task 6）**

在跑着本分支的实例上，用一次真实 mobile-chat 会话让 Captain 推荐套餐，然后打印那条消息的 `content_attributes` 与样本比对：

```bash
ssh ubuntu@32.236.75.213 'cd /opt/chatwoot-upstream && sudo -n docker compose exec -T rails bundle exec rails runner "
  m = Message.where(content_type: :cards).order(:id).last
  puts JSON.pretty_generate(m.content_attributes)
  puts m.valid? ? \"valid\" : m.errors.full_messages.inspect
"'
```

（`/opt/chatwoot-upstream` 是实例安装位置、`docker compose` 在那里要 `sudo -n` —— 见 `deploy/upstream-comparison/README.md`。）

Expected: `variant` = `novyro_plan_group`；items 的键与样本一致；`valid`

---

### Task 6: 实例侧收尾（需你确认后再做）

**Files:**
- Modify: `captain-materials/apply_captain_scenarios.rb`（本地未跟踪材料）
- 部署：`deploy/upstream-comparison/deploy.sh`

- [ ] **Step 1: 改 Scenario 指令**：把「用 `recommend_plans` 推荐套餐」改成两步 —— 先用 [Recommend Plans](tool://recommend_plans) 取数据，再在同一轮用 [Create Purchase Action](tool://create_purchase_action) 把主推的 sku 发成卡片；未成功发卡前不要向客户报具体套餐或价格。

- [ ] **Step 2: 部署**

```bash
deploy/upstream-comparison/deploy.sh --build-only   # 先构建（约 40 分钟，跑在服务器上）
deploy/upstream-comparison/deploy.sh --status       # 确认镜像
```

构建后按 `CLAUDE.md` 的验证清单检查 Vite manifest entrypoints 与 `/app/.git_sha`，再 `deploy.sh` 切换。

- [ ] **Step 3: 部署后验证**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://32.236.75.213:81/super_admin/sign_in   # 期望 200
```

再用 Task 5 Step 5 的 runner 核对真实会话里的卡片 JSON。

---

## 自检记录

- **spec 覆盖**：契约字段与上限 → Task 2；文案字典与回退 → Task 1；组卡与上游对账 → Task 3；工具形状与投递 → Task 4；契约样本对照 → Task 5；`catalog_env` 兜底 → Task 3（`catalog_environment`）；Scenario 指令 → Task 6。spec §7 的客户端待办不在本仓库，未排任务。
- **未覆盖**：spec §9 的 R1（web 端 404）与 R3（未审校译文）是已知风险，无代码可写；R6 的"最多 5 张"由 `CARD_LIMIT` 与校验器双重兜住。
- **本机限制**：所有 `bundle exec rspec` 步骤都标了「需在有工具链的环境执行」，汇报时不得写成"测试通过"。

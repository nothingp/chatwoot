# 用 Chatwoot 原生承载 mobile-chat 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Chatwoot 里新增 `/public/api/v1/mobile_chat/session`（建会话、验身份、写 contact）与 `/mobile-chat`（302 到原生 `/widget`）两个入口，让 `esimgo-web` 只改两个配置项就能把客服从 `ai-bridge` 切到 Chatwoot。

**Architecture:** `/mobile-chat` 先用 `ContactInboxWithContactBuilder` 建好带身份的 `contact_inbox`，再用 `Widget::TokenService` 签出 `cw_conversation` 并 302 到 `/widget`。`WidgetsController#set_contact` 按 `source_id` 找到已存在的 `contact_inbox`，因此 `build_contact` 不会重建——`widgets/show.html.erb`、`WidgetsController`、widget app **全部零改动**。

**Tech Stack:** Rails 7.0（`ActionController::Base` / `PublicController`）、RSpec + FactoryBot + WebMock、Redis（`Redis::Alfred`）、`SafeFetch`（`lib/safe_fetch.rb`）、Vue 无关（本计划只动后端）。

**Spec:** `docs/superpowers/specs/2026-10-08-mobile-chat-native-design.md`

## Global Constraints

- **前端响应契约是 `.strict()`**（来源 `esimgo-web/src/features/customer-support/customer-support-types.ts`），顶层**只能**有 5 个 key：`ok`(字面量 `true`)、`chatUrl`(1–2048 字符)、`expiresAt`(正整数)、`identityCookieScope`(严格子对象)、`identityContinuity`(严格子对象)。多一个字段前端整体拒收。
- `chatUrl` 必须等于 `{FRONTEND_URL}/mobile-chat?session=<uuid v4>`，**且只有一个查询参数**。
- `identityCookieScope` 的 key 固定为 `origin` / `path`(字面量 `'/'`) / `conversationCookieName`(字面量 `'cw_conversation'`) / `userCookieName`(匹配 `^cw_user_[A-Za-z0-9_-]{1,128}$`)。
- `identityContinuity` 只返回 `{ confirmed: false }`。`key` 在契约里是可选的，本次不返回（spec §10）。
- `expiresAt` 是**毫秒**时间戳；前端要求 `expiresAt > now + 1000` 且 `<= now + 20min`。session TTL = 20 分钟。
- `chatUrl` 与 `identityCookieScope.origin` 的 base 都是 `ENV['FRONTEND_URL']`，必须与前端 `config.chatOrigin` 完全一致（含协议）。
- 业务 API：`GET {NOVYRO_API_BASE_URL}{NOVYRO_USER_INFO_PATH}`，默认路径 `/v2/esim/user/info`；请求头 `token`(会员凭据) + `x-api-key` + `site-id`；**成功 = HTTP 2xx 且 `code == 0`（Integer 严格相等，字符串 `'0'` 不算）**，会员 ID 取 `data.id`，昵称 `data.nickname`，邮箱 `data.email`。
- `identifier` 是**长期契约**（持久化进 `contact.identifier`）：会员 `member_<id>`、匿名 `guest_<installationId>_<anonymousProfileId>`，两个 UUID 一律**转小写**。
- **本次不加 Origin 白名单**（2026-10-08 决定）：`/public/api/*` 在 `cors.rb` 里是 `origins '*'`，接口对任何站点开放。不要加 `MOBILE_CHAT_ALLOWED_ORIGINS`。
- **本次每次建会话都刷新 `contact.custom_attributes['app_token']`**（2026-10-08 决定）：`ContactInboxWithContactBuilder` 命中已存在的 contact 时不会更新它，且业务 API 返回的 email 命中已有 contact 时 `create_contact` 根本不会被调用。
- 业务 API 失败**一律降级为匿名**（不阻断建会话）；只有**配置缺失**（`MOBILE_CHAT_INBOX_ID` / `NOVYRO_*` / `FRONTEND_URL`）才 500。
- 请求参数非法（`installationId` / `anonymousProfileId` 不是 UUID v4）→ **400**（spec §6 的明确契约）。
- Ruby 代码遵守 RuboCop（行宽 150）；commit 用 Conventional Commits，不引用 Claude。

---

## 文件结构

**新增**

| 文件 | 职责 |
|---|---|
| `lib/custom_exceptions/mobile_chat/not_configured.rb` | 配置缺失异常，携带缺失的配置名 |
| `app/services/mobile_chat/config.rb` | 唯一读取 mobile-chat 配置的地方；缺失即抛异常 |
| `app/services/mobile_chat/novyro_client.rb` | 业务 API 单次调用（`SafeFetch` + 响应形状校验），失败返回 `nil` |
| `app/services/mobile_chat/identity_resolver.rb` | 由 token / 设备标识派生 `Identity`（identifier/name/email/token） |
| `app/services/mobile_chat/session_store.rb` | Redis session 的写/读/TTL/过期时间 |
| `app/services/mobile_chat/contact_credentials.rb` | 把会员 `app_token` 刷进 contact |
| `app/controllers/public/api/v1/mobile_chat/sessions_controller.rb` | `POST /public/api/v1/mobile_chat/session` |
| `app/controllers/mobile_chat_controller.rb` | `GET /mobile-chat` → 302 到 `/widget`，过期时 410 |
| `app/views/mobile_chat/expired.html.erb` | 410 简单页 |

**修改**

| 文件 | 改动 |
|---|---|
| `config/routes.rb` | 两处新增行（`/mobile-chat` + `/public/api/v1/mobile_chat/session`） |
| `config/installation_config.yml` | 追加 6 个配置项 |
| `lib/redis/redis_keys.rb` | 追加 1 个常量 |
| `config/locales/en.yml` | 追加 `mobile_chat.expired.*` |

**测试**

`spec/services/mobile_chat/config_spec.rb`、`novyro_client_spec.rb`、`identity_resolver_spec.rb`、`session_store_spec.rb`、`contact_credentials_spec.rb`；`spec/requests/public/api/v1/mobile_chat/sessions_spec.rb`；`spec/requests/mobile_chat_spec.rb`

**依赖顺序**：Task 1 → 2 → 3 → 6；Task 4 → 6 → 7；Task 5 → 6。串行执行即可。

---

### Task 1: 配置读取与配置项

**Files:**
- Create: `lib/custom_exceptions/mobile_chat/not_configured.rb`
- Create: `app/services/mobile_chat/config.rb`
- Modify: `config/installation_config.yml`（追加到文件末尾）
- Test: `spec/services/mobile_chat/config_spec.rb`

**Interfaces:**
- Consumes: `InstallationConfig`（`find_by(name:).value`）、`CustomExceptions::Base`（`lib/custom_exceptions/base.rb`）
- Produces:
  - `CustomExceptions::MobileChat::NotConfigured`，构造参数是缺失的配置名（`raise Klass, 'NAME'`）
  - `MobileChat::Config.inbox` → `::Inbox`（找不到就抛异常）
  - `MobileChat::Config.frontend_url` → `String`
  - `MobileChat::Config.novyro_user_info_url` → `String`
  - `MobileChat::Config.novyro_headers` → `Hash{'Accept'=>'application/json', 'x-api-key'=>, 'site-id'=>}`

- [ ] **Step 1: 追加配置项**

在 `config/installation_config.yml` 文件**末尾**追加：

```yaml

## ------ Mobile chat (mobile app customer service) ------ ##
- name: MOBILE_CHAT_INBOX_ID
  display_title: 'Mobile Chat Inbox ID'
  description: 'Chatwoot inbox that carries mobile app customer service sessions. Must be a Website inbox; determines website_token and contact identity.'
  value:
  locked: false
- name: NOVYRO_API_BASE_URL
  display_title: 'Novyro API Base URL'
  description: 'Base URL of the Novyro app API, including the /api prefix, e.g. https://api.example.com/api'
  value:
  locked: false
- name: NOVYRO_API_KEY
  display_title: 'Novyro API Key'
  description: 'Service-level x-api-key sent with Novyro app API requests.'
  value:
  locked: false
  type: secret
- name: NOVYRO_SITE_ID
  display_title: 'Novyro Site ID'
  description: 'site-id header sent with Novyro app API requests.'
  value:
  locked: false
- name: NOVYRO_USER_INFO_PATH
  display_title: 'Novyro User Info Path'
  description: 'Path that verifies an app member token. Default: /v2/esim/user/info'
  value: '/v2/esim/user/info'
  locked: false
- name: NOVYRO_USER_ORDERS_PATH
  display_title: 'Novyro User Orders Path'
  description: 'User orders path, used by later phases. Default: /v2/esim/user/orders'
  value: '/v2/esim/user/orders'
  locked: false
## ------ End of mobile chat ------ ##
```

> 这些配置只在 `ConfigLoader.new.process` 里落库（`lib/tasks/db_enhancements.rake` 挂在 `db:migrate` 上），所以部署时要跑一次 `db:migrate` 或在 Super Admin → App Configs 里保存一次。Task 8 覆盖。

- [ ] **Step 2: 写配置缺失异常**

创建 `lib/custom_exceptions/mobile_chat/not_configured.rb`：

```ruby
# frozen_string_literal: true

class CustomExceptions::MobileChat::NotConfigured < CustomExceptions::Base
  def message
    "Mobile chat is not configured: #{@data}"
  end

  def to_hash
    { error: message }
  end

  def http_status
    :internal_server_error
  end
end
```

> `CustomExceptions::Base#initialize(data)` 收一个参数（`lib/custom_exceptions/base.rb`），所以抛出时必须写成 `raise CustomExceptions::MobileChat::NotConfigured, 'NAME'`。

- [ ] **Step 3: 写失败的测试**

创建 `spec/services/mobile_chat/config_spec.rb`：

```ruby
require 'rails_helper'

RSpec.describe MobileChat::Config do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  before do
    create(:installation_config, name: 'MOBILE_CHAT_INBOX_ID', value: inbox.id)
    create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'https://api.example.com/api')
    create(:installation_config, name: 'NOVYRO_USER_INFO_PATH', value: '/v2/esim/user/info')
    create(:installation_config, name: 'NOVYRO_API_KEY', value: 'service-key')
    create(:installation_config, name: 'NOVYRO_SITE_ID', value: '10000')
  end

  describe '.inbox' do
    it 'returns the configured inbox' do
      expect(described_class.inbox).to eq(inbox)
    end

    it 'raises with the config name when the inbox id is blank' do
      InstallationConfig.where(name: 'MOBILE_CHAT_INBOX_ID').delete_all

      expect { described_class.inbox }
        .to raise_error(CustomExceptions::MobileChat::NotConfigured, /MOBILE_CHAT_INBOX_ID/)
    end

    it 'raises with the config name when the configured inbox no longer exists' do
      inbox.destroy!

      expect { described_class.inbox }
        .to raise_error(CustomExceptions::MobileChat::NotConfigured, /MOBILE_CHAT_INBOX_ID/)
    end
  end

  describe '.frontend_url' do
    it 'returns FRONTEND_URL' do
      with_modified_env(FRONTEND_URL: 'https://chat.example.com') do
        expect(described_class.frontend_url).to eq('https://chat.example.com')
      end
    end

    it 'raises with the env var name when FRONTEND_URL is blank' do
      with_modified_env(FRONTEND_URL: nil) do
        expect { described_class.frontend_url }
          .to raise_error(CustomExceptions::MobileChat::NotConfigured, /FRONTEND_URL/)
      end
    end
  end

  describe '.novyro_user_info_url' do
    it 'joins the base url with the configured path' do
      expect(described_class.novyro_user_info_url).to eq('https://api.example.com/api/v2/esim/user/info')
    end
  end

  describe '.novyro_headers' do
    it 'returns the service credential headers' do
      expect(described_class.novyro_headers).to eq(
        'Accept' => 'application/json',
        'x-api-key' => 'service-key',
        'site-id' => '10000'
      )
    end

    it 'raises with the config name when the api key is missing' do
      InstallationConfig.where(name: 'NOVYRO_API_KEY').delete_all

      expect { described_class.novyro_headers }
        .to raise_error(CustomExceptions::MobileChat::NotConfigured, /NOVYRO_API_KEY/)
    end
  end
end
```

- [ ] **Step 4: 跑测试确认失败**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/config_spec.rb
```

Expected: FAIL / ERROR —`NameError: uninitialized constant MobileChat::Config`（`uninitialized constant MobileChat`）。

- [ ] **Step 5: 写实现**

创建 `app/services/mobile_chat/config.rb`：

```ruby
module MobileChat::Config
  # These values back deployment configuration that must exist in production: a blank
  # value is an operator error, so raise instead of silently degrading to anonymous.
  def self.inbox
    ::Inbox.find_by(id: value('MOBILE_CHAT_INBOX_ID')) ||
      raise(CustomExceptions::MobileChat::NotConfigured, 'MOBILE_CHAT_INBOX_ID')
  end

  def self.frontend_url
    ENV.fetch('FRONTEND_URL', nil).presence ||
      raise(CustomExceptions::MobileChat::NotConfigured, 'FRONTEND_URL')
  end

  def self.novyro_user_info_url
    "#{value('NOVYRO_API_BASE_URL')}#{value('NOVYRO_USER_INFO_PATH')}"
  end

  def self.novyro_headers
    {
      'Accept' => 'application/json',
      'x-api-key' => value('NOVYRO_API_KEY'),
      'site-id' => value('NOVYRO_SITE_ID')
    }
  end

  def self.value(name)
    InstallationConfig.find_by(name: name)&.value.presence ||
      raise(CustomExceptions::MobileChat::NotConfigured, name)
  end
end
```

- [ ] **Step 6: 跑测试确认通过**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/config_spec.rb
```

Expected: PASS（7 examples）。

- [ ] **Step 7: Lint**

```bash
eval "$(rbenv init -)" && bundle exec rubocop -a app/services/mobile_chat lib/custom_exceptions/mobile_chat spec/services/mobile_chat
```

- [ ] **Step 8: Commit**

```bash
git add app/services/mobile_chat/config.rb lib/custom_exceptions/mobile_chat/not_configured.rb \
  config/installation_config.yml spec/services/mobile_chat/config_spec.rb
git commit -m "feat(mobile-chat): add locked config readers and installation configs"
```

---

### Task 2: 业务 API 客户端

**Files:**
- Create: `app/services/mobile_chat/novyro_client.rb`
- Test: `spec/services/mobile_chat/novyro_client_spec.rb`

**Interfaces:**
- Consumes: `MobileChat::Config.novyro_user_info_url` / `.novyro_headers`（Task 1）、`SafeFetch.fetch(url, **, &block)`（`lib/safe_fetch.rb`）
- Produces: `MobileChat::NovyroClient.new(token:).user_info` → `Hash`（业务 API 的 `data`，字符串 key）或 `nil`。**永远不抛异常**，`nil` 表示"不是有效会员"。

业务 API 的响应形状（`novyro-promax/docs/api/novyro-api-doc.md` §2.1）：

```json
{ "code": 0, "msg": "success", "data": { "id": 1001, "nickname": "Zhang San", "email": "user@example.com", "is_guest": false } }
```

`SafeFetch.fetch` 在非 2xx 时抛 `SafeFetch::HttpError`；它需要一个 block 并 yield 一个持有 `tempfile` 的 `Result`（所以必须传 `validate_content_type: false`，否则 `application/json` 会被拒）。

- [ ] **Step 1: 写失败的测试**

创建 `spec/services/mobile_chat/novyro_client_spec.rb`：

```ruby
require 'rails_helper'

RSpec.describe MobileChat::NovyroClient do
  let(:user_info_url) { 'https://api.example.com/api/v2/esim/user/info' }
  let(:client) { described_class.new(token: 'member-token') }

  before do
    create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'https://api.example.com/api')
    create(:installation_config, name: 'NOVYRO_USER_INFO_PATH', value: '/v2/esim/user/info')
    create(:installation_config, name: 'NOVYRO_API_KEY', value: 'service-key')
    create(:installation_config, name: 'NOVYRO_SITE_ID', value: '10000')

    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('api.example.com').and_return(['93.184.216.34'])
  end

  it 'sends the app token together with the service credentials' do
    request = stub_request(:get, user_info_url)
              .with(headers: { 'token' => 'member-token', 'x-api-key' => 'service-key', 'site-id' => '10000' })
              .to_return(status: 200, body: { code: 0, msg: 'success',
                                              data: { id: 1001, nickname: 'Zhang San', email: 'user@example.com' } }.to_json)

    expect(client.user_info).to eq('id' => 1001, 'nickname' => 'Zhang San', 'email' => 'user@example.com')
    expect(request).to have_been_requested
  end

  it 'returns nil for a non-success business code' do
    stub_request(:get, user_info_url).to_return(status: 200, body: { code: 401, msg: 'unauthorized' }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil for a string success code' do
    stub_request(:get, user_info_url).to_return(status: 200, body: { code: '0', data: { id: 1001 } }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the payload carries no member id' do
    stub_request(:get, user_info_url).to_return(status: 200, body: { code: 0, data: { nickname: 'Zhang San' } }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil when data is not an object' do
    stub_request(:get, user_info_url).to_return(status: 200, body: { code: 0, data: nil }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the upstream refuses the token' do
    stub_request(:get, user_info_url).to_return(status: 401, body: { code: 401 }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the upstream fails' do
    stub_request(:get, user_info_url).to_return(status: 500, body: 'boom')

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the upstream times out' do
    stub_request(:get, user_info_url).to_timeout

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the body is not JSON' do
    stub_request(:get, user_info_url).to_return(status: 200, body: '<html>nope</html>')

    expect(client.user_info).to be_nil
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/novyro_client_spec.rb
```

Expected: FAIL / ERROR —`NameError: uninitialized constant MobileChat::NovyroClient`。

- [ ] **Step 3: 写实现**

创建 `app/services/mobile_chat/novyro_client.rb`：

```ruby
class MobileChat::NovyroClient
  SUCCESS_CODE = 0
  MAX_RESPONSE_BYTES = 64.kilobytes
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5
  SENSITIVE_HEADERS = %w[token x-api-key].freeze

  def initialize(token:)
    @token = token
  end

  # Returns the verified member payload, or nil when the token does not identify an app
  # member. Every upstream failure degrades to anonymous chat instead of blocking session
  # creation; the caller cannot tell "invalid token" apart from "API down" by design.
  def user_info
    payload = JSON.parse(fetch)
    return unless payload.is_a?(Hash) && payload['code'] == SUCCESS_CODE

    data = payload['data']
    return unless data.is_a?(Hash) && data['id'].present?

    data
  rescue SafeFetch::Error, JSON::ParserError => e
    Rails.logger.warn("[MobileChat] member verification degraded to anonymous: #{e.class}: #{e.message}")
    nil
  end

  private

  attr_reader :token

  def fetch
    body = +''
    SafeFetch.fetch(
      MobileChat::Config.novyro_user_info_url,
      headers: MobileChat::Config.novyro_headers.merge('token' => token),
      sensitive_headers: SENSITIVE_HEADERS,
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT,
      max_bytes: MAX_RESPONSE_BYTES,
      validate_content_type: false
    ) { |result| body = result.tempfile.read }
    body
  end
end
```

> `sensitive_headers` 让 `SafeFetch` 在**跨源重定向**时丢掉 `token` / `x-api-key`（与 `enterprise/lib/captain/tools/http_tool.rb` 同款做法）。

- [ ] **Step 4: 跑测试确认通过**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/novyro_client_spec.rb
```

Expected: PASS（9 examples）。

- [ ] **Step 5: Lint + Commit**

```bash
eval "$(rbenv init -)" && bundle exec rubocop -a app/services/mobile_chat/novyro_client.rb spec/services/mobile_chat/novyro_client_spec.rb
git add app/services/mobile_chat/novyro_client.rb spec/services/mobile_chat/novyro_client_spec.rb
git commit -m "feat(mobile-chat): add novyro member verification client"
```

---

### Task 3: 身份派生

**Files:**
- Create: `app/services/mobile_chat/identity_resolver.rb`
- Test: `spec/services/mobile_chat/identity_resolver_spec.rb`

**Interfaces:**
- Consumes: `MobileChat::NovyroClient.new(token:).user_info`（Task 2）
- Produces:
  - `MobileChat::IdentityResolver.new(token:, installation_id:, anonymous_profile_id:).perform` → `MobileChat::IdentityResolver::Identity`
  - `Identity` 成员：`identifier`(String)、`name`(String|nil)、`email`(String|nil)、`token`(String|nil)
  - `Identity#contact_attributes` → `Hash{identifier:, name:, email:}`，可直接喂给 `ContactInboxWithContactBuilder`

- [ ] **Step 1: 写失败的测试**

创建 `spec/services/mobile_chat/identity_resolver_spec.rb`：

```ruby
require 'rails_helper'

RSpec.describe MobileChat::IdentityResolver do
  let(:installation_id) { '3f2504e0-4f89-41d3-9a0c-0305e82c3301' }
  let(:anonymous_profile_id) { '9c858901-8a57-4791-81fe-4c455b099bc9' }
  let(:token) { nil }
  let(:user_info) { nil }

  describe '#perform without a token' do
    it 'derives the guest identifier from the installation and profile ids' do
      identity = described_class.new(
        token: nil, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.identifier).to eq("guest_#{installation_id}_#{anonymous_profile_id}")
      expect(identity.name).to be_nil
      expect(identity.email).to be_nil
      expect(identity.token).to be_nil
    end

    it 'lower cases the guest identifier so the persisted contract is canonical' do
      identity = described_class.new(
        token: nil, installation_id: installation_id.upcase, anonymous_profile_id: anonymous_profile_id.upcase
      ).perform

      expect(identity.identifier).to eq("guest_#{installation_id}_#{anonymous_profile_id}")
    end

    it 'does not call the business API' do
      expect(MobileChat::NovyroClient).not_to receive(:new)

      described_class.new(
        token: nil, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform
    end
  end

  describe '#perform with a token the business API accepts' do
    let(:token) { 'member-token' }

    before do
      allow(MobileChat::NovyroClient).to receive(:new).with(token: token).and_return(
        instance_double(MobileChat::NovyroClient,
                        user_info: { 'id' => 1001, 'nickname' => 'Zhang San', 'email' => 'user@example.com' })
      )
    end

    it 'derives the member identifier and keeps the token' do
      identity = described_class.new(
        token: token, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.identifier).to eq('member_1001')
      expect(identity.name).to eq('Zhang San')
      expect(identity.email).to eq('user@example.com')
      expect(identity.token).to eq('member-token')
    end
  end

  describe '#perform with a token the business API rejects' do
    let(:token) { 'expired-token' }

    before do
      allow(MobileChat::NovyroClient).to receive(:new).with(token: token).and_return(
        instance_double(MobileChat::NovyroClient, user_info: nil)
      )
    end

    it 'falls back to the guest identity' do
      identity = described_class.new(
        token: token, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.identifier).to eq("guest_#{installation_id}_#{anonymous_profile_id}")
    end

    it 'does not carry the rejected token' do
      identity = described_class.new(
        token: token, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.token).to be_nil
    end
  end

  describe 'Identity#contact_attributes' do
    it 'maps to the builder attribute hash' do
      identity = described_class.new(
        token: nil, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.contact_attributes).to eq(
        identifier: "guest_#{installation_id}_#{anonymous_profile_id}",
        name: nil,
        email: nil
      )
    end
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/identity_resolver_spec.rb
```

Expected: FAIL / ERROR —`NameError: uninitialized constant MobileChat::IdentityResolver`。

- [ ] **Step 3: 写实现**

创建 `app/services/mobile_chat/identity_resolver.rb`：

```ruby
class MobileChat::IdentityResolver
  # identifier is persisted into contact.identifier, so this shape is a long-term contract.
  Identity = Data.define(:identifier, :name, :email, :token) do
    def contact_attributes
      { identifier: identifier, name: name, email: email }
    end
  end

  MEMBER_PREFIX = 'member_'
  GUEST_PREFIX = 'guest_'

  def initialize(token:, installation_id:, anonymous_profile_id:)
    @token = token.presence
    @installation_id = installation_id.to_s.downcase
    @anonymous_profile_id = anonymous_profile_id.to_s.downcase
  end

  def perform
    member_identity || guest_identity
  end

  private

  attr_reader :token, :installation_id, :anonymous_profile_id

  def member_identity
    return if token.blank?

    member = MobileChat::NovyroClient.new(token: token).user_info
    return if member.blank?

    Identity.new(
      identifier: "#{MEMBER_PREFIX}#{member['id']}",
      name: member['nickname'].presence,
      email: member['email'].presence,
      token: token
    )
  end

  def guest_identity
    Identity.new(
      identifier: "#{GUEST_PREFIX}#{installation_id}_#{anonymous_profile_id}",
      name: nil,
      email: nil,
      token: nil
    )
  end
end
```

- [ ] **Step 4: 跑测试确认通过**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/identity_resolver_spec.rb
```

Expected: PASS（8 examples）。

- [ ] **Step 5: Lint + Commit**

```bash
eval "$(rbenv init -)" && bundle exec rubocop -a app/services/mobile_chat/identity_resolver.rb spec/services/mobile_chat/identity_resolver_spec.rb
git add app/services/mobile_chat/identity_resolver.rb spec/services/mobile_chat/identity_resolver_spec.rb
git commit -m "feat(mobile-chat): derive member and guest contact identities"
```

---

### Task 4: session 存储

**Files:**
- Modify: `lib/redis/redis_keys.rb`（在 `## Device verification` 块之后追加）
- Create: `app/services/mobile_chat/session_store.rb`
- Test: `spec/services/mobile_chat/session_store_spec.rb`

**Interfaces:**
- Consumes: `Redis::Alfred.setex(key, value, expiry)` / `.get(key)` / `.ttl(key)`（`lib/redis/alfred.rb`；注意 `setex` 的参数顺序是 key, value, expiry）
- Produces:
  - `MobileChat::SessionStore.create(contact_inbox:, inbox:)` → session id（`String`，UUID v4）
  - `MobileChat::SessionStore.read(session_id)` → `Hash{'inbox_id'=>Integer, 'contact_inbox_id'=>Integer}` 或 `nil`
  - `MobileChat::SessionStore.expires_at` → 毫秒时间戳（`Integer`）
  - `MobileChat::SessionStore.key(session_id)` → Redis key

- [ ] **Step 1: 追加 Redis key 常量**

在 `lib/redis/redis_keys.rb` 的 `## Device verification (cloud sign-in challenge)` 块之后、`end` 之前追加：

```ruby
  ## Mobile chat
  # Short-lived handoff between session creation and the widget redirect
  MOBILE_CHAT_SESSION = 'MOBILE_CHAT_SESSION::%<id>s'.freeze
```

- [ ] **Step 2: 写失败的测试**

创建 `spec/services/mobile_chat/session_store_spec.rb`：

```ruby
require 'rails_helper'

RSpec.describe MobileChat::SessionStore do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account)) }

  describe '.create' do
    it 'returns a uuid v4 session id' do
      session_id = described_class.create(contact_inbox: contact_inbox, inbox: inbox)

      expect(session_id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    it 'stores the inbox and contact inbox ids under a 20 minute ttl' do
      session_id = described_class.create(contact_inbox: contact_inbox, inbox: inbox)

      expect(Redis::Alfred.ttl(described_class.key(session_id))).to be_within(5).of(20.minutes.to_i)
    end
  end

  describe '.read' do
    it 'returns the stored ids' do
      session_id = described_class.create(contact_inbox: contact_inbox, inbox: inbox)

      expect(described_class.read(session_id)).to eq(
        'contact_inbox_id' => contact_inbox.id,
        'inbox_id' => inbox.id
      )
    end

    it 'returns nil for an unknown session' do
      expect(described_class.read(SecureRandom.uuid)).to be_nil
    end

    it 'returns nil for a blank session id' do
      expect(described_class.read(nil)).to be_nil
    end
  end

  describe '.expires_at' do
    it 'returns a millisecond timestamp inside the 20 minute window' do
      now = Time.current.to_i * 1000

      expect(described_class.expires_at).to be_a(Integer)
      expect(described_class.expires_at).to be > now + 1_000
      expect(described_class.expires_at).to be <= now + (20 * 60 * 1000)
    end
  end
end
```

> session id 是随机 UUID，留下的 key 20 分钟后自己过期，不需要清理。

- [ ] **Step 3: 跑测试确认失败**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/session_store_spec.rb
```

Expected: FAIL / ERROR —`NameError: uninitialized constant MobileChat::SessionStore`。

- [ ] **Step 4: 写实现**

创建 `app/services/mobile_chat/session_store.rb`：

```ruby
class MobileChat::SessionStore
  TTL = 20.minutes

  class << self
    def create(contact_inbox:, inbox:)
      session_id = SecureRandom.uuid
      Redis::Alfred.setex(
        key(session_id),
        { contact_inbox_id: contact_inbox.id, inbox_id: inbox.id }.to_json,
        TTL
      )
      session_id
    end

    # Repeatable until the TTL expires: refreshing the customer-facing iframe reuses it.
    def read(session_id)
      return if session_id.blank?

      raw = Redis::Alfred.get(key(session_id))
      return if raw.blank?

      JSON.parse(raw)
    end

    # The frontend contract validates expiresAt as a millisecond timestamp.
    def expires_at
      (Time.current + TTL).to_i * 1000
    end

    def key(session_id)
      format(Redis::RedisKeys::MOBILE_CHAT_SESSION, id: session_id)
    end
  end
end
```

- [ ] **Step 5: 跑测试确认通过**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/session_store_spec.rb
```

Expected: PASS（6 examples）。

- [ ] **Step 6: Lint + Commit**

```bash
eval "$(rbenv init -)" && bundle exec rubocop -a app/services/mobile_chat/session_store.rb lib/redis/redis_keys.rb spec/services/mobile_chat/session_store_spec.rb
git add app/services/mobile_chat/session_store.rb lib/redis/redis_keys.rb spec/services/mobile_chat/session_store_spec.rb
git commit -m "feat(mobile-chat): store short-lived chat sessions in redis"
```

---

### Task 5: 刷新 contact 上的会员凭据

**Files:**
- Create: `app/services/mobile_chat/contact_credentials.rb`
- Test: `spec/services/mobile_chat/contact_credentials_spec.rb`

**Interfaces:**
- Consumes: `Contact#custom_attributes`（jsonb `Hash`）、`Contact#update!`
- Produces: `MobileChat::ContactCredentials.sync(contact, token)` → `nil`（无返回值的副作用）

**为什么单独做这一步**：`ContactInboxWithContactBuilder#find_or_create_contact_and_contact_inbox` 命中已有 `contact_inbox` 时**直接返回**，不会更新 contact；而 `find_contact` 会用业务 API 返回的 email 命中已有 contact，此时 `create_contact`（唯一带上 `app_token` 的地方）根本不会被调用。所以凭据必须显式刷新，否则会员二次登录时 Captain 工具会拿到旧 token。

- [ ] **Step 1: 写失败的测试**

创建 `spec/services/mobile_chat/contact_credentials_spec.rb`：

```ruby
require 'rails_helper'

RSpec.describe MobileChat::ContactCredentials do
  let(:contact) { create(:contact, account: create(:account)) }

  it 'writes the app token onto the contact' do
    described_class.sync(contact, 'member-token')

    expect(contact.reload.custom_attributes['app_token']).to eq('member-token')
  end

  it 'refreshes a rotated app token' do
    contact.update!(custom_attributes: { 'app_token' => 'old-token' })

    described_class.sync(contact, 'new-token')

    expect(contact.reload.custom_attributes['app_token']).to eq('new-token')
  end

  it 'keeps unrelated custom attributes' do
    contact.update!(custom_attributes: { 'plan' => 'gold', 'app_token' => 'old-token' })

    described_class.sync(contact, 'new-token')

    expect(contact.reload.custom_attributes).to eq('plan' => 'gold', 'app_token' => 'new-token')
  end

  it 'leaves the contact alone for an anonymous session' do
    expect { described_class.sync(contact, nil) }.not_to(change { contact.reload.updated_at })
  end

  it 'does not write when the token is unchanged' do
    contact.update!(custom_attributes: { 'app_token' => 'same-token' })

    expect { described_class.sync(contact, 'same-token') }.not_to(change { contact.reload.updated_at })
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/contact_credentials_spec.rb
```

Expected: FAIL / ERROR —`NameError: uninitialized constant MobileChat::ContactCredentials`。

- [ ] **Step 3: 写实现**

创建 `app/services/mobile_chat/contact_credentials.rb`：

```ruby
module MobileChat::ContactCredentials
  APP_TOKEN_KEY = 'app_token'

  # ContactInboxWithContactBuilder does not touch an existing contact, and skips creating
  # one entirely when the verified email matches an existing contact. Refresh explicitly so
  # later Captain tools always read the app token of the current login.
  def self.sync(contact, token)
    return if token.blank?
    return if contact.custom_attributes[APP_TOKEN_KEY] == token

    contact.update!(custom_attributes: contact.custom_attributes.merge(APP_TOKEN_KEY => token))
  end
end
```

- [ ] **Step 4: 跑测试确认通过**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat/contact_credentials_spec.rb
```

Expected: PASS（5 examples）。

- [ ] **Step 5: Lint + Commit**

```bash
eval "$(rbenv init -)" && bundle exec rubocop -a app/services/mobile_chat/contact_credentials.rb spec/services/mobile_chat/contact_credentials_spec.rb
git add app/services/mobile_chat/contact_credentials.rb spec/services/mobile_chat/contact_credentials_spec.rb
git commit -m "feat(mobile-chat): refresh the app token on the contact"
```

---

### Task 6: session 端点

**Files:**
- Modify: `config/routes.rb`（`namespace :public` 块内，`resources :csat_survey` 之后）
- Create: `app/controllers/public/api/v1/mobile_chat/sessions_controller.rb`
- Test: `spec/requests/public/api/v1/mobile_chat/sessions_spec.rb`

**Interfaces:**
- Consumes: Task 1–5 的全部接口
- Produces: `POST /public/api/v1/mobile_chat/session` → 200 + 严格契约 JSON；400 参数非法；500 配置缺失

**为什么类名是 `Public::Api::V1::MobileChat::SessionsController`**：路由嵌套是 `namespace :public / :api / :v1 / :mobile_chat`，Rails 会按这个嵌套推导常量（既有同类：`app/controllers/public/api/v1/inboxes_controller.rb` → `Public::Api::V1::InboxesController`）。spec §9 表里写的 `app/controllers/api/mobile_chat/...` 与 §4.8 写的 `Api::MobileChat::...` 都和路由不符，以 Rails 约定为准。

**为什么继承 `PublicController`**：它 `skip_before_action :verify_authenticity_token`（跨域 POST 不带 CSRF token），并且 include 了 `RequestExceptionHandler`（提供 `render_internal_server_error`）。

- [ ] **Step 1: 加路由**

在 `config/routes.rb` 的 `namespace :public, defaults: { format: 'json' } do` → `namespace :api` → `namespace :v1` 块内，`resources :csat_survey, only: [:show, :update]` 之后插入：

```ruby
        namespace :mobile_chat do
          resource :session, only: [:create]
        end
```

> 必须在 `/public/api/` 下：`config/initializers/cors.rb` 只对 `resource '/public/api/*'` 开了 `origins '*'`。挂到 `/api/*` 就需要开 `ENABLE_API_CORS`，而前端是**跨域**调用的。

- [ ] **Step 2: 写失败的测试**

创建 `spec/requests/public/api/v1/mobile_chat/sessions_spec.rb`：

```ruby
require 'rails_helper'

RSpec.describe 'Public mobile chat session API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:installation_id) { '3f2504e0-4f89-41d3-9a0c-0305e82c3301' }
  let(:anonymous_profile_id) { '9c858901-8a57-4791-81fe-4c455b099bc9' }
  let(:frontend_url) { 'https://chat.example.com' }
  let(:user_info_url) { 'https://api.example.com/api/v2/esim/user/info' }
  let(:payload) do
    {
      platform: 'web',
      locale: 'zh_CN',
      systemLanguage: 'zh-CN',
      catalogEnvironment: 'prod',
      entryPoint: 'web_home_buy_esim',
      appVersion: 'web-0.1.0',
      installationId: installation_id,
      anonymousProfileId: anonymous_profile_id,
      resetChatIdentity: false
    }
  end
  let(:guest_identifier) { "guest_#{installation_id}_#{anonymous_profile_id}" }

  before do
    create(:installation_config, name: 'MOBILE_CHAT_INBOX_ID', value: inbox.id)
    create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'https://api.example.com/api')
    create(:installation_config, name: 'NOVYRO_USER_INFO_PATH', value: '/v2/esim/user/info')
    create(:installation_config, name: 'NOVYRO_API_KEY', value: 'service-key')
    create(:installation_config, name: 'NOVYRO_SITE_ID', value: '10000')

    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('api.example.com').and_return(['93.184.216.34'])
  end

  it 'returns exactly the strict frontend response contract' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.keys).to contain_exactly('ok', 'chatUrl', 'expiresAt', 'identityCookieScope', 'identityContinuity')
    expect(body['ok']).to be(true)
    expect(body['identityContinuity']).to eq('confirmed' => false)
    expect(body['identityCookieScope']).to eq(
      'origin' => frontend_url,
      'path' => '/',
      'conversationCookieName' => 'cw_conversation',
      'userCookieName' => "cw_user_#{inbox.channel.website_token}"
    )
  end

  it 'returns a chat url that is exactly chatOrigin/mobile-chat with one session param' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    chat_url = URI.parse(response.parsed_body['chatUrl'])
    query = URI.decode_www_form(chat_url.query)

    expect(chat_url.origin).to eq(frontend_url)
    expect(chat_url.path).to eq('/mobile-chat')
    expect(query.map(&:first)).to eq(['session'])
    expect(query.first.last).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
  end

  it 'returns expiresAt as milliseconds inside the 20 minute window' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    now = Time.current.to_i * 1000
    expect(response.parsed_body['expiresAt']).to be_a(Integer)
    expect(response.parsed_body['expiresAt']).to be > now + 1_000
    expect(response.parsed_body['expiresAt']).to be <= now + (20 * 60 * 1000)
  end

  it 'creates one guest contact and reuses the same contact inbox on the next call' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      expect do
        2.times { post '/public/api/v1/mobile_chat/session', params: payload, as: :json }
      end.to change(ContactInbox, :count).by(1)
    end

    expect(Contact.last.identifier).to eq(guest_identifier)
  end

  it 'identifies a verified member and stores the app token' do
    stub_request(:get, user_info_url).to_return(
      status: 200,
      body: { code: 0, msg: 'success',
              data: { id: 1001, nickname: 'Zhang San', email: 'member@example.com' } }.to_json
    )

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'member-token' }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(Contact.last.identifier).to eq('member_1001')
    expect(Contact.last.name).to eq('Zhang San')
    expect(Contact.last.custom_attributes['app_token']).to eq('member-token')
  end

  it 'refreshes the app token when a member returns with a new one' do
    allow(MobileChat::NovyroClient).to receive(:new).with(token: 'first-token').and_return(
      instance_double(MobileChat::NovyroClient, user_info: { 'id' => 1001, 'nickname' => 'Zhang San' })
    )
    allow(MobileChat::NovyroClient).to receive(:new).with(token: 'second-token').and_return(
      instance_double(MobileChat::NovyroClient, user_info: { 'id' => 1001, 'nickname' => 'Zhang San' })
    )

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'first-token' }, as: :json
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'second-token' }, as: :json
    end

    expect(Contact.count).to eq(1)
    expect(Contact.last.custom_attributes['app_token']).to eq('second-token')
  end

  it 'falls back to a guest session when the business API rejects the token' do
    stub_request(:get, user_info_url).to_return(status: 401, body: { code: 401, msg: 'unauthorized' }.to_json)

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'stale-token' }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(Contact.last.identifier).to eq(guest_identifier)
    expect(Contact.last.custom_attributes).not_to have_key('app_token')
  end

  it 'falls back to a guest session when the business API times out' do
    stub_request(:get, user_info_url).to_timeout

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'member-token' }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(Contact.last.identifier).to eq(guest_identifier)
  end

  it 'rejects a malformed installation id without creating a contact' do
    expect do
      post '/public/api/v1/mobile_chat/session', params: payload.merge(installationId: 'not-a-uuid'), as: :json
    end.not_to(change(Contact, :count))

    expect(response).to have_http_status(:bad_request)
  end

  it 'rejects a malformed anonymous profile id' do
    post '/public/api/v1/mobile_chat/session', params: payload.merge(anonymousProfileId: 'not-a-uuid'), as: :json

    expect(response).to have_http_status(:bad_request)
  end

  it 'returns 500 when the mobile chat inbox is not configured' do
    InstallationConfig.where(name: 'MOBILE_CHAT_INBOX_ID').delete_all

    post '/public/api/v1/mobile_chat/session', params: payload, as: :json

    expect(response).to have_http_status(:internal_server_error)
  end

  it 'returns 500 when FRONTEND_URL is not configured' do
    with_modified_env(FRONTEND_URL: nil) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    expect(response).to have_http_status(:internal_server_error)
  end

  it 'answers the CORS preflight for the session endpoint' do
    options '/public/api/v1/mobile_chat/session',
            headers: { 'Origin' => 'https://app.example.com', 'Access-Control-Request-Method' => 'POST' }

    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
  end

  it 'sends the CORS header on the actual POST' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload,
                                               headers: { 'Origin' => 'https://app.example.com' }, as: :json
    end

    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
  end
end
```

- [ ] **Step 3: 跑测试确认失败**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/requests/public/api/v1/mobile_chat/sessions_spec.rb
```

Expected: FAIL — 路由不存在（`ActionController::RoutingError` / 404）。

- [ ] **Step 4: 写实现**

创建 `app/controllers/public/api/v1/mobile_chat/sessions_controller.rb`：

```ruby
class Public::Api::V1::MobileChat::SessionsController < PublicController
  UUID_V4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  rescue_from CustomExceptions::MobileChat::NotConfigured, with: :render_not_configured

  def create
    return render_bad_request('installationId must be a UUID v4') unless uuid_v4?(params[:installationId])
    return render_bad_request('anonymousProfileId must be a UUID v4') unless uuid_v4?(params[:anonymousProfileId])

    identity = identity_resolver.perform
    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      contact_attributes: identity.contact_attributes,
      source_id: identity.identifier,
      hmac_verified: true
    ).perform

    MobileChat::ContactCredentials.sync(contact_inbox.contact, identity.token)

    render json: session_response(MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox))
  end

  private

  def identity_resolver
    MobileChat::IdentityResolver.new(
      token: request.headers['token'],
      installation_id: params[:installationId],
      anonymous_profile_id: params[:anonymousProfileId]
    )
  end

  # source_id must stay stable: ContactInboxWithContactBuilder looks the contact inbox up by
  # source_id, and conversations hang off the contact inbox. Using the identifier keeps a
  # returning customer in the same conversation history instead of starting from scratch.
  def inbox
    @inbox ||= MobileChat::Config.inbox
  end

  def uuid_v4?(value)
    UUID_V4.match?(value.to_s)
  end

  def render_bad_request(message)
    render json: { error: message }, status: :bad_request
  end

  def render_not_configured(exception)
    Rails.logger.error("[MobileChat] #{exception.message}")
    render_internal_server_error(exception.message)
  end

  def session_response(session_id)
    {
      ok: true,
      chatUrl: "#{MobileChat::Config.frontend_url}/mobile-chat?session=#{session_id}",
      expiresAt: MobileChat::SessionStore.expires_at,
      identityCookieScope: {
        origin: MobileChat::Config.frontend_url,
        path: '/',
        conversationCookieName: 'cw_conversation',
        userCookieName: "cw_user_#{inbox.channel.website_token}"
      },
      identityContinuity: { confirmed: false }
    }
  end
end
```

- [ ] **Step 5: 跑测试确认通过**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/requests/public/api/v1/mobile_chat/sessions_spec.rb
```

Expected: PASS（13 examples）。

如果 CORS 两条 example 失败，先确认第 1 步的路由确实插在 `namespace :public` 块里，再确认没开 `ENABLE_API_CORS`。

- [ ] **Step 6: Lint + Commit**

```bash
eval "$(rbenv init -)" && bundle exec rubocop -a app/controllers/public/api/v1/mobile_chat config/routes.rb spec/requests/public/api/v1/mobile_chat
git add config/routes.rb app/controllers/public/api/v1/mobile_chat/sessions_controller.rb \
  spec/requests/public/api/v1/mobile_chat/sessions_spec.rb
git commit -m "feat(mobile-chat): create widget sessions for the mobile chat entry point"
```

---

### Task 7: `/mobile-chat` 跳转

**Files:**
- Modify: `config/routes.rb`（非 API-only 分支内，`resource :widget, only: [:show]` 之后）
- Create: `app/controllers/mobile_chat_controller.rb`
- Create: `app/views/mobile_chat/expired.html.erb`
- Modify: `config/locales/en.yml`（追加到文件末尾）
- Test: `spec/requests/mobile_chat_spec.rb`

**Interfaces:**
- Consumes: `MobileChat::SessionStore.read`（Task 4）、`Widget::TokenService.new(payload: { source_id:, inbox_id: }).generate_token`（`app/services/widget/token_service.rb`）、`widget_path`（来自 `resource :widget`）
- Produces: `GET /mobile-chat?session=<uuid>` → 302 到 `/widget?website_token=..&cw_conversation=..`；session 缺失/失效/联系人不在了 → 410

**为什么路由放在非 API-only 分支里**：`/widget` 本身就在 `config/routes.rb` 的 `else`（非 `CW_API_ONLY_SERVER`）分支里，跳转目标不存在时 `/mobile-chat` 没有意义。

**为什么 410 页一定要删 `X-Frame-Options`**：Rails 7 的 `ActionDispatch` 默认给所有响应带上 `X-Frame-Options: SAMEORIGIN`（这就是 `WidgetsController#allow_iframe_requests` 里要 `response.headers.delete('X-Frame-Options')` 的原因）。302 不渲染所以无所谓，但 410 页是**在跨域 iframe 里渲染的**，不删就是一片空白。

- [ ] **Step 1: 加路由**

在 `config/routes.rb` 中 `resource :widget, only: [:show]` 那一行**之后**插入：

```ruby
    get '/mobile-chat', to: 'mobile_chat#show'
```

- [ ] **Step 2: 写 i18n 与过期页**

在 `config/locales/en.yml` 文件**末尾**追加（顶层 key 与 `  public_portal:` 同级，缩进 2 空格）：

```yaml
  mobile_chat:
    expired:
      title: 'This chat session has expired'
      description: 'Please reopen customer service from the app.'
```

创建 `app/views/mobile_chat/expired.html.erb`：

```erb
<!DOCTYPE html>
<html lang="<%= I18n.locale %>">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex">
    <title><%= t('mobile_chat.expired.title') %></title>
  </head>
  <body>
    <h1><%= t('mobile_chat.expired.title') %></h1>
    <p><%= t('mobile_chat.expired.description') %></p>
  </body>
</html>
```

> 这个页面不引入任何 CSS bundle（它是 iframe 里的兜底状态），所以只写语义 HTML，不写自定义 CSS / 内联样式。

- [ ] **Step 3: 写失败的测试**

创建 `spec/requests/mobile_chat_spec.rb`：

```ruby
require 'rails_helper'

RSpec.describe 'Mobile chat handoff', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  it 'redirects to the widget with a conversation token for the stored contact inbox' do
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)

    get '/mobile-chat', params: { session: session_id }

    expect(response).to have_http_status(:found)
    location = URI.parse(response.location)
    query = URI.decode_www_form(location.query).to_h
    expect(location.path).to eq('/widget')
    expect(query['website_token']).to eq(inbox.channel.website_token)

    payload = Widget::TokenService.new(token: query['cw_conversation']).decode_token
    expect(payload[:source_id]).to eq(contact_inbox.source_id)
    expect(payload[:inbox_id]).to eq(inbox.id)
  end

  it 'renders 410 for an unknown session' do
    get '/mobile-chat', params: { session: SecureRandom.uuid }

    expect(response).to have_http_status(:gone)
  end

  it 'renders 410 for a blank session' do
    get '/mobile-chat'

    expect(response).to have_http_status(:gone)
  end

  it 'renders 410 when the session outlived its contact inbox' do
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)
    contact_inbox.destroy!

    get '/mobile-chat', params: { session: session_id }

    expect(response).to have_http_status(:gone)
  end

  it 'keeps the expired page embeddable in a cross-origin iframe' do
    get '/mobile-chat', params: { session: SecureRandom.uuid }

    expect(response.headers['X-Frame-Options']).to be_nil
  end

  it 'hands the pre-created contact to the widget instead of creating a new one' do
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)

    get '/mobile-chat', params: { session: session_id }
    get response.location

    expect(response).to have_http_status(:ok)
    expect(Contact.count).to eq(1)
    expect(ContactInbox.count).to eq(1)
  end
end
```

- [ ] **Step 4: 跑测试确认失败**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/requests/mobile_chat_spec.rb
```

Expected: FAIL — 路由不存在（404）。

- [ ] **Step 5: 写实现**

创建 `app/controllers/mobile_chat_controller.rb`：

```ruby
class MobileChatController < ActionController::Base
  layout false

  # Renders nothing itself: it only builds the widget token and hands the browser over to
  # the stock widget, which is why neither widgets/show.html.erb nor the widget app change.
  def show
    session = MobileChat::SessionStore.read(params[:session])
    return render_expired if session.blank?

    inbox = ::Inbox.find_by(id: session['inbox_id'])
    contact_inbox = ::ContactInbox.find_by(id: session['contact_inbox_id'])
    return render_expired if inbox.blank? || contact_inbox.blank?

    redirect_to widget_path(
      website_token: inbox.channel.website_token,
      cw_conversation: widget_token(inbox, contact_inbox)
    )
  end

  private

  def render_expired
    # The 410 renders inside the customer-facing iframe, so it has to stay frameable.
    response.headers.delete('X-Frame-Options')
    render :expired, status: :gone
  end

  def widget_token(inbox, contact_inbox)
    Widget::TokenService.new(
      payload: { source_id: contact_inbox.source_id, inbox_id: inbox.id }
    ).generate_token
  end
end
```

> 同一个 `chatUrl` 可以反复打开：`SessionStore.read` 用的是 `Redis::Alfred.get`，不删 key，直到 TTL 到期。

- [ ] **Step 6: 跑测试确认通过**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/requests/mobile_chat_spec.rb
```

Expected: PASS（6 examples）。

- [ ] **Step 7: 跑全量新测试**

```bash
eval "$(rbenv init -)" && bundle exec rspec spec/services/mobile_chat spec/requests/mobile_chat_spec.rb \
  spec/requests/public/api/v1/mobile_chat
```

Expected: PASS（40 examples 左右）。

- [ ] **Step 8: Lint + Commit**

```bash
eval "$(rbenv init -)" && bundle exec rubocop -a app/controllers/mobile_chat_controller.rb config/routes.rb spec/requests/mobile_chat_spec.rb
git add config/routes.rb app/controllers/mobile_chat_controller.rb app/views/mobile_chat/expired.html.erb \
  config/locales/en.yml spec/requests/mobile_chat_spec.rb
git commit -m "feat(mobile-chat): hand mobile chat sessions to the native widget"
```

---

### Task 8: 上线配置与人工验证

**Files:** 无代码改动（这是一次真实的部署与验证）

**Interfaces:**
- Consumes: Task 1–7 的全部产物
- Produces: 一个可用的 `{chatOrigin}/mobile-chat?session=<uuid>` 入口

- [ ] **Step 1: 落库安装配置**

加进 `installation_config.yml` 的配置只在 `ConfigLoader.new.process` 时写库（`lib/tasks/db_enhancements.rake` 挂在 `db:migrate` 上）：

```bash
eval "$(rbenv init -)" && bundle exec rake db:migrate
```

或者直接在 Super Admin → Settings → App Configs 里保存一次（该页读的就是 `ConfigLoader.new.general_configs`）。

- [ ] **Step 2: 填值**

Super Admin → Settings → App Configs（或 `rails runner`）：

```
MOBILE_CHAT_INBOX_ID   = <一个 Website 渠道的 inbox id>
NOVYRO_API_BASE_URL    = https://<业务 API 域名>/api
NOVYRO_API_KEY         = <服务级 x-api-key>
NOVYRO_SITE_ID         = <site id>
NOVYRO_USER_INFO_PATH  = /v2/esim/user/info    （默认值，不填也生效）
```

确认 `FRONTEND_URL` 是**公网可达**的 Chatwoot 地址，且与前端 `config.chatOrigin` 完全一致（含协议）。

- [ ] **Step 3: 把 iframe 域名放进 inbox 白名单**

打开 Task 8 Step 2 里那个 inbox 的 Website 渠道设置：

- 若 `allowedDomains`（Allowed domains）**留空** → `WidgetsController#allow_iframe_requests` 会删掉 `X-Frame-Options`，任何站点都能嵌。
- 若填了域名 → 它会改发 `Content-Security-Policy: frame-ancestors <domains>`，**必须**把 `esimgo-web` 的 origin（以及 App webview 需要的规则）写进去，否则浏览器直接拒绝渲染 iframe。

这一步漏了的症状是"接口全对，iframe 一片空白"。

- [ ] **Step 4: 用真实 token 验证验身份端点**

先确认业务 API 的成功码与字段，别让所有会员静默降级：

```bash
curl -s -i 'https://<业务 API 域名>/api/v2/esim/user/info' \
  -H 'token: <一个真实会员 token>' \
  -H 'x-api-key: <NOVYRO_API_KEY>' \
  -H 'site-id: <NOVYRO_SITE_ID>'
```

必须看到 HTTP 200 且 body 是 `{"code":0, ..., "data":{"id":<会员ID>, ...}}`。

- 如果 `code` 不是 `0`（例如返回 `1`），说明这个 host 走的是另一套网关约定——**停在这里**，改 `MobileChat::NovyroClient::SUCCESS_CODE` 与 `NOVYRO_USER_INFO_PATH` 后再上线，并同步改 Task 2 的 spec。
- 如果 401/404，说明 token 或 `x-api-key` / `site-id` 不对。

- [ ] **Step 5: 端到端验证**

```bash
eval "$(rbenv init -)" && bundle exec rails runner '
  puts MobileChat::Config.inbox.id
  puts MobileChat::Config.novyro_user_info_url
'
```

然后跑一遍真实流程：

1. `POST https://<chatwoot 域>/public/api/v1/mobile_chat/session` 带上一个真实 token，确认响应里 `chatUrl` 的 origin 等于 `FRONTEND_URL`。
2. 浏览器里打开这个 `chatUrl`，确认落地在 `/widget?...`，DevTools 里 `window.authToken` 不是空串。
3. 在 Chatwoot 后台看到该联系人，`identifier` 是 `member_<会员ID>`，`custom_attributes.app_token` 是刚发的 token。
4. 让客服回一条消息，确认客户侧能收到（证明会话真的绑在同一个 `contact_inbox` 上）。
5. 用同一个 token 再建一次会话，确认**联系人数量没有增加**、且后台仍是同一个 `contact_inbox`。

- [ ] **Step 6: 改 esimgo-web 的两个配置项**

```
chatOrigin      : https://<chatwoot 域>                              （原为 bridge 域）
sessionEndpoint : https://<chatwoot 域>/public/api/v1/mobile_chat/session
```

`chatOrigin` 必须与 `FRONTEND_URL` 完全一致（含协议），否则前端的 `chatUrl.origin === config.chatOrigin` 校验会拒。

- [ ] **Step 7: 确认调用方是否带 `token` header**

`esimgo-web` 的 `customer-support-session-service.ts` 目前只发 `accept` / `content-type` 两个头（靠 `credentials: 'include'` 带 cookie），**不带 `token` header**。所以官网访客会一律以匿名身份进入。

要让官网会员也被识别，二选一（**都不在本次范围**，属于 spec §10 的后续阶段）：

- 前端改成带 `token` header（需要前端配合），或
- 后端增加 Web session cookie 的验身份路径（`ai-bridge` 里的 `verifyWebUser` 就是这个）。

改配置本身不影响匿名链路：匿名的建会话、跳转、聊天全部可用。

- [ ] **Step 8: 提交配置说明（可选）**

若这轮上线需要留下操作记录，把上面 Step 1–4 的最终值（不含密钥明文）记到 `docs/` 下对应环境文档里并提交：

```bash
git add docs/
git commit -m "docs(mobile-chat): record deployment configuration"
```

---

## 与 spec 的偏差（实施时已决定，需评审确认）

1. **控制器命名空间**：spec §9 表写 `app/controllers/api/mobile_chat/sessions_controller.rb`、§4.8 写 `Api::MobileChat::SessionsController`，但路由嵌套是 `public/api/v1/mobile_chat`，Rails 推导出的常量是 `Public::Api::V1::MobileChat::SessionsController`（与既有 `Public::Api::V1::InboxesController` 一致）。本计划按路由推导的类名实现。
2. **新增 `MobileChat::ContactCredentials`**（spec 没有）：spec §4.2 把 `app_token` 交给 `ContactInboxWithContactBuilder`，但 builder 命中已有 contact 时不更新、email 命中已有 contact 时压根不建 contact。按 2026-10-08 的决定改为每次建会话显式刷新。
3. **新增 `MobileChat::Config`**（spec 只列了配置键）：把 6 个配置 + `FRONTEND_URL` 的读取集中到一处，缺失即抛 `CustomExceptions::MobileChat::NotConfigured` → 500 + 日志（对齐 spec §6「只有配置缺失才 500」与"对必须存在的配置用直接读取、失败要响"）。
4. **`/mobile-chat` 路由位置**：spec 说"顶层，与 `resource :widget` 同级"——确实如此，但那个层级在**非 API-only 分支**内（`/widget` 只在那里存在），所以 `CW_API_ONLY_SERVER=true` 的部署拿不到 `/mobile-chat`。
5. **410 页删 `X-Frame-Options`**（spec 未提及）：跨域 iframe 里渲染 410 必须删，否则空白。
6. **不做 `identityContinuityKey`**（spec §10）：响应固定 `{ confirmed: false }`。副作用是：带 `identityContinuityKey` 的客户端会轮换一次 `anonymousProfileId` 并重试一次建会话（`customer-support-session-service.ts` 的逻辑），第二次成功；之后 `commit(undefined)` 清掉 key，不再重试。
7. **不再校验其它请求字段**：`platform` / `locale` / `currency` / `catalogEnvironment` / `entryPoint` / `appVersion` / `resetChatIdentity` / `identityContinuityKey` 本次全部忽略（spec §2 的契约要求它们存在，但不影响建会话）。
8. **`esimgo-web` 现在不带 `token` header**：见 Task 8 Step 7。本次上线后官网访客一律匿名；会员识别只对带 `token` header 的调用方生效。

## spec §11 风险项的落地方式

| 风险 | 本计划的处理 |
|---|---|
| **R1 · CORS 全开** | 按 2026-10-08 决定**不做**白名单。`/public/api/*` 保持 `origins '*'`，接口本身不返回敏感数据，且要有效 token 才能拿到会员身份。 |
| **R2 · `identifier` 是长期契约** | Task 3 把格式与大小写规范化固定下来，并用 `lower cases the guest identifier` 一条 example 钉住。**上线后不要改这个格式**。 |
| **R3 · `app_token` 会进 Captain 的 prompt** | `MobileChat::ContactCredentials` 写的 `custom_attributes['app_token']` 会被 `captain/prompts/snippets/contact.liquid` 逐条渲染进每一轮 system prompt。本次接受；Captain 真正接入后要复核长随机串是否干扰模型判断。 |
| **R4 · 单一 inbox** | `MOBILE_CHAT_INBOX_ID` 只支持一个 inbox。将来官网 / App webview 需要不同 inbox 时，改成按 Origin 映射（`InstallationConfig` 存一个 map），**不要**在这里加 inbox 数组。 |
| **R5 · 业务 API 失败静默降级** | `MobileChat::NovyroClient#user_info` 的 `Rails.logger.warn` 是可观测信号（形如 `[MobileChat] member verification degraded to anonymous: ...`）。响应契约不放降级标记（会破坏 `.strict()`）。 |

## Enterprise 影响

已确认无需改动 `enterprise/`：`enterprise/` 下没有 `config/routes.rb`（不存在路由覆盖），也没有 `PublicController` 的 `prepend_mod_with` 或任何 `MobileChat` 引用。本计划全是新增文件 + `config/routes.rb` / `config/installation_config.yml` / `lib/redis/redis_keys.rb` / `config/locales/en.yml` 的追加行，`WidgetsController`（Enterprise 有 `ensure_location_is_supported` 覆盖）**一行都不动**。

## 两条回归护栏

计划里有两条 example 专门盯住"错了不报错、症状很隐蔽"的地方，评审时不要把它们当重复覆盖删掉：

- **`source_id` 稳定** —— Task 6 的 `creates one guest contact and reuses the same contact inbox on the next call`、`refreshes the app token when a member returns with a new one`。`source_id` 为空或不稳定时不会报错，只是每次打开客服都是全新会话、历史断掉。
- **命名空间挂在 `/public/api/`** —— Task 6 的两条 CORS example。挂到 `/api/*` 时后端全对，只有浏览器预检失败。

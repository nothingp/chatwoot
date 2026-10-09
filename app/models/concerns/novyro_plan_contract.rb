require 'json'
require 'uri'

# The plan cards the mobile app renders natively. This variant is its own contract: the app
# reads badge and facts and builds the checkout URL from the action's query terms, so a card
# outside this shape renders wrong or offers a dead button -- reject at write time instead.
#
# The message validator enforces this at write time and MobileChat::CaptainToolkit builds cards
# against it, so the numbers, the key sets and the postback payload shape live here rather than on
# either side.
module NovyroPlanContract
  NOVYRO_PLAN_VARIANT = 'novyro_plan_group'.freeze
  NOVYRO_PLAN_TOP_LEVEL_KEYS = [:variant, :items].freeze
  NOVYRO_PLAN_REQUIRED_ITEM_KEYS = [:title, :description, :media_url, :badge, :facts, :actions].freeze
  # The one optional item key, in both the symbol and the string form a jsonb round trip leaves it
  # in: the card builder omits it when the product has no https flag, so absent is valid.
  NOVYRO_PLAN_OPTIONAL_ITEM_KEYS = [:country_image, 'country_image'].freeze
  NOVYRO_PLAN_MAX_ITEMS = 5
  NOVYRO_PLAN_MAX_FACTS = 3
  NOVYRO_PLAN_FACT_KEYS = [:icon, :label, :value].freeze
  NOVYRO_PLAN_FACT_ICONS = %w[wifi calendar wallet].freeze
  # The app opens a link itself; the website, which embeds the widget in a sandboxed iframe, gets
  # the same checkout url as a postback payload for the host page to open.
  NOVYRO_PLAN_ACTION_KEYS = [:type, :text, :uri].freeze
  NOVYRO_PLAN_POSTBACK_KEYS = [:type, :text, :payload].freeze
  NOVYRO_PLAN_POSTBACK_TYPE = 'checkout'.freeze
  # The url stays so the host page can always fall back to it; the two ids let it build its own
  # destination instead. The session values a client declared when it opened the chat are echoed
  # back alongside them. The app token is deliberately not among them: it is a credential, and the
  # payload leaves the server.
  NOVYRO_PLAN_PAYLOAD_REQUIRED_KEYS = %w[type url goods_id sku_id].freeze
  NOVYRO_PLAN_PAYLOAD_SESSION_KEYS = %w[locale platform catalog_environment currency].freeze
  NOVYRO_PLAN_ACTION_PATH = '/app-actions/checkout'.freeze
  NOVYRO_PLAN_ACTION_QUERY_KEYS = %w[catalog_env goods_id sku_id].freeze
  NOVYRO_PLAN_CATALOG_ENVIRONMENTS = %w[dev test prod].freeze
  NOVYRO_PLAN_MAX_SAFE_ID = 9_007_199_254_740_991
  NOVYRO_PLAN_TEXT_LIMITS = {
    title: 160, description: 500, badge: 40, country_image: 2048,
    fact_label: 40, fact_value: 120, action_text: 120, action_uri: 2048, action_payload: 2048
  }.freeze

  # The ids are positive integers the app and the checkout both index by, so anything else -- a
  # zero, a sign, a float, a string that is not digits -- is a term the other side rejects.
  def self.checkout_id?(value)
    value.is_a?(String) && value.match?(/\A[0-9]+\z/) &&
      value.to_i.between?(1, NOVYRO_PLAN_MAX_SAFE_ID)
  end

  # Chatwoot hands a postback payload to the host page as the string it is. A payload that does not
  # parse, or does not carry the shape the host page reads, is nil here rather than an exception
  # the writer has to rescue.
  def self.postback_checkout(payload)
    parsed = payload.is_a?(String) ? JSON.parse(payload) : nil
    return unless postback_payload?(parsed)

    parsed
  rescue JSON::ParserError
    nil
  end

  def self.postback_payload?(parsed)
    return false unless parsed.is_a?(Hash)
    return false unless (parsed.keys - NOVYRO_PLAN_PAYLOAD_SESSION_KEYS).sort == NOVYRO_PLAN_PAYLOAD_REQUIRED_KEYS

    checkout_payload?(parsed)
  end

  def self.checkout_payload?(parsed)
    return false unless parsed['type'] == NOVYRO_PLAN_POSTBACK_TYPE && checkout_url?(parsed['url'])
    return false unless checkout_id?(parsed['goods_id']) && checkout_id?(parsed['sku_id'])

    parsed.values_at(*NOVYRO_PLAN_PAYLOAD_SESSION_KEYS).compact.all?(String)
  end

  # The destination the host page opens: an https page with a host. Anything else is a link the
  # customer cannot complete a purchase with.
  def self.checkout_url?(value)
    return false unless value.is_a?(String)

    uri = URI.parse(value)
    uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?
  rescue URI::InvalidURIError
    false
  end
end

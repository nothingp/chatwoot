require 'json'

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
  NOVYRO_PLAN_PAYLOAD_KEYS = %w[type url].freeze
  NOVYRO_PLAN_ACTION_PATH = '/app-actions/checkout'.freeze
  NOVYRO_PLAN_ACTION_QUERY_KEYS = %w[catalog_env goods_id sku_id].freeze
  NOVYRO_PLAN_CATALOG_ENVIRONMENTS = %w[dev test prod].freeze
  NOVYRO_PLAN_MAX_SAFE_ID = 9_007_199_254_740_991
  NOVYRO_PLAN_TEXT_LIMITS = {
    title: 160, description: 500, badge: 40, country_image: 2048,
    fact_label: 40, fact_value: 120, action_text: 120, action_uri: 2048, action_payload: 2048
  }.freeze

  # Chatwoot hands a postback payload to the host page as the string it is, so it has to be JSON
  # carrying exactly the checkout type and the url. A payload that does not parse, or does not carry
  # that shape, is nil here rather than an exception the writer has to rescue.
  def self.postback_checkout_url(payload)
    parsed = payload.is_a?(String) ? JSON.parse(payload) : {}
    return unless parsed.is_a?(Hash) && parsed.keys.sort == NOVYRO_PLAN_PAYLOAD_KEYS
    return unless parsed['type'] == NOVYRO_PLAN_POSTBACK_TYPE && parsed['url'].is_a?(String)

    parsed['url']
  rescue JSON::ParserError
    nil
  end
end

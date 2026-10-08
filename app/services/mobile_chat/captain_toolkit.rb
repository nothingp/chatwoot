# Business methods behind the Captain tools.
#
# Everything that couples a Chatwoot conversation to Novyro for tool calls lives in this one
# file: resolving the customer's credentials off the conversation, calling Novyro, and shaping
# the response for an LLM. Each Captain::Tools::*Tool class is a thin adapter that resolves the
# conversation from the tool context and calls the matching method here.
#
# These methods never raise on upstream failures. The caller is an LLM tool call, so every
# failure becomes a structured `{ ok: false, error: ... }` the model can read back to the
# customer. Missing *configuration* is the one exception: it raises NotConfigured, which the
# tool call surfaces as an error, because it is a deployment bug rather than a customer problem.
class MobileChat::CaptainToolkit
  # Novyro's production host reports success as code 1 (see MobileChat::NovyroClient).
  SUCCESS_CODE = MobileChat::NovyroClient::SUCCESS_CODE
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 8
  MAX_RESPONSE_BYTES = 256.kilobytes

  RECOMMENDATIONS_PATH = '/v2/esim/product/recommendations'.freeze
  PRODUCT_SEARCH_PATH = '/v2/esim/product/search'.freeze
  PRODUCT_DETAILS_PATH = '/v2/esim/product/details'.freeze

  # Bound what reaches the prompt: orders and plan lists are small in practice, and an
  # unbounded passthrough would blow up the model's context.
  MAX_ITEMS = 20
  MAX_STRING = 400
  # One call posts one card per SKU, and the widget stacks them full width, so a dozen of them
  # is a wall. This is also the message validator's own item limit.
  CARD_LIMIT = 5

  # The raw order payload also carries QR codes, full ICCIDs and internal supplier fields.
  # Whitelist instead of passing it through: this is rendered into the customer's prompt.
  ORDER_KEYS = %i[
    order_id status product_name amount currency
    created_at paid_at completed_at purchased_at
    data_size_value data_size_unit data_unlimited billing_period_days plan_status
    data_total_gb data_used_gb data_remaining_gb
    activate_before activated_at expires_at remaining_data_gb
  ].freeze

  SIGN_IN_REQUIRED =
    'This customer is not signed in, so their own order data is not available. ' \
    'Ask them to sign in to the app and try again.'.freeze
  UPSTREAM_UNAVAILABLE =
    'The order and plan service is temporarily unavailable. Ask the customer to try again in a moment.'.freeze

  def initialize(conversation)
    @conversation = conversation
  end

  # --- Orders: these read the customer's own account, so their app token is required ---

  def list_orders
    return { ok: false, error: SIGN_IN_REQUIRED } if member_token.blank?

    response = fetch_json(MobileChat::Config.value('NOVYRO_USER_ORDERS_PATH'), token: member_token)
    return response if response[:ok] == false

    orders = Array(order_collection(response[:data]))
    { ok: true, count: orders.size, orders: orders.first(MAX_ITEMS).map { |order| present_order(order) } }
  end

  def get_order_details(params)
    return { ok: false, error: SIGN_IN_REQUIRED } if member_token.blank?

    wanted = [param(params, :order_id), param(params, :order_no)].compact_blank.map(&:to_s)
    return { ok: false, error: 'Provide order_id or order_no.' } if wanted.empty?

    response = fetch_json(MobileChat::Config.value('NOVYRO_USER_ORDERS_PATH'), token: member_token)
    return response if response[:ok] == false

    orders = Array(order_collection(response[:data])).map { |order| present_order(order) }
    match = orders.find { |order| wanted.include?(order[:order_id].to_s) }
    return { ok: false, error: 'No order with that id belongs to this customer.' } if match.blank?

    { ok: true, order: match }
  end

  # --- Products: public endpoints, service credentials only, no customer token needed ---

  def recommend_plans(params)
    country = param(params, :country_code).to_s.strip.upcase
    period = param(params, :billing_period).to_i
    return { ok: false, error: 'country_code (ISO 3166-1 alpha-2) and billing_period (days) are required.' } if country.blank? || period <= 0

    response = fetch_catalog_json(RECOMMENDATIONS_PATH, query: { country_code: country, billing_period: period })
    return response if response[:ok] == false

    plans = Array(response.dig(:data, 'recommendations'))
    { ok: true, count: plans.size, plans: plans.first(MAX_ITEMS).map { |plan| present_plan(plan) } }
  end

  def search_products(params)
    keyword = param(params, :keyword).to_s.strip
    return { ok: false, error: 'keyword is required.' } if keyword.blank?

    response = fetch_catalog_json(PRODUCT_SEARCH_PATH, query: { keyword: keyword })
    return response if response[:ok] == false

    data = response[:data] || {}
    # all_products is a map keyed by product id, not an array.
    products = (data['all_products'].presence || {}).map { |id, product| present_product(product, id) }
    {
      ok: true,
      count: products.size,
      products: products.first(MAX_ITEMS),
      country_product_ids: Array(data['country_products']).first(MAX_ITEMS),
      regional_product_ids: Array(data['regional_products']).first(MAX_ITEMS)
    }
  end

  def get_product_details(params)
    product_id = param(params, :product_id).to_s.strip
    return { ok: false, error: 'product_id is required.' } if product_id.blank?

    response = fetch_catalog_json(PRODUCT_DETAILS_PATH, query: { product_id: product_id })
    return response if response[:ok] == false

    product = response.dig(:data, 'product') || response[:data]
    return { ok: false, error: UPSTREAM_UNAVAILABLE } unless product.is_a?(Hash)

    { ok: true, product: present_product(product, product_id) }
  end

  # The model decides which SKUs to recommend; the numbers, the copy and the checkout link come
  # from here. One call posts one message: order is rank, because the app renders the first item
  # as the main card and the rest as alternatives.
  def purchase_actions(params)
    product_id = param(params, :product_id).to_s
    sku_ids = Array(param(params, :sku_ids)).map(&:to_s).first(CARD_LIMIT)
    invalid = purchase_request_error(product_id, sku_ids)
    return { ok: false, error: invalid } if invalid

    response = fetch_catalog_json(PRODUCT_DETAILS_PATH, query: { product_id: product_id })
    return response if response[:ok] == false

    product = present_product(response.dig(:data, 'product') || response[:data], product_id)
    skus = selected_skus(product, sku_ids)
    return { ok: false, error: 'Those sku_ids are not part of that product.' } if skus.any?(&:nil?)

    { ok: true, cards: purchase_cards(product, skus, params) }
  end

  private

  attr_reader :conversation

  def contact
    @contact ||= conversation&.contact_inbox&.contact
  end

  # Written at session creation and refreshed on every new session (MobileChat::ContactCredentials).
  def member_token
    @member_token ||= contact&.custom_attributes&.dig('app_token').presence
  end

  # → { ok: true, data: Hash } | { ok: false, error: String }
  def fetch_json(path, query: {}, token: nil, headers: {})
    url = MobileChat::Config.novyro_url(path)
    url = "#{url}?#{URI.encode_www_form(query)}" if query.present?

    request_headers = MobileChat::Config.novyro_headers.merge(headers)
    request_headers['token'] = token if token.present?

    body = +''
    SafeFetch.fetch(
      url,
      headers: request_headers,
      sensitive_headers: %w[token x-api-key],
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT,
      max_bytes: MAX_RESPONSE_BYTES,
      validate_content_type: false
    ) { |result| body = result.tempfile.read }

    payload = JSON.parse(body)
    return { ok: false, error: UPSTREAM_UNAVAILABLE } unless payload.is_a?(Hash)
    return { ok: false, error: SIGN_IN_REQUIRED } if [401, 403].include?(payload['code'])
    return { ok: false, error: UPSTREAM_UNAVAILABLE } unless payload['code'] == SUCCESS_CODE

    data = payload['data']
    # Success without an object body means the upstream contract moved; report it as unavailable
    # rather than handing the model a nil to reason about.
    return { ok: false, error: UPSTREAM_UNAVAILABLE } unless data.is_a?(Hash) || data.is_a?(Array)

    { ok: true, data: data }
  rescue SafeFetch::Error, JSON::ParserError => e
    Rails.logger.warn("[MobileChat] captain tool call failed: #{e.class}: #{e.message}")
    { ok: false, error: UPSTREAM_UNAVAILABLE }
  end

  # Product reads carry the customer's language and currency as headers, which is how upstream
  # decides the copy and the price it answers with (the bridge did the same via publicHeaders).
  # Orders are read with the member token and keep the plain service headers.
  def fetch_catalog_json(path, query: {})
    fetch_json(path, query: query, headers: { 'lang' => client_locale, 'currency' => client_currency })
  end

  def order_collection(data)
    return data['orders'] if data.is_a?(Hash) && data['orders'].is_a?(Array)
    return data if data.is_a?(Array)

    []
  end

  def param(params, key)
    return if params.blank?

    params[key] || params[key.to_s]
  end

  # --- Shaping. Key lookup is deliberately tolerant of camelCase/snake_case: the upstream
  # responses mix the two and we would rather find a field than silently drop it.

  def present_order(raw)
    order = hash(raw)
    data_plan = hash(value(order, :data_plan, :dataPlan))
    sku = hash(sku_source(order))
    size_value, size_unit = data_size(order, sku)

    {
      order_id: value(order, :order_no, :orderNo, :order_id, :orderId, :id),
      status: value(order, :normalized_order_status, :normalizedOrderStatus, :order_status, :orderStatus, :status)&.to_s&.upcase,
      product_name: value(order, :product_name, :productName, :order_summary, :orderSummary) ||
        value(sku, :product_name, :productName, :country_code, :countryCode),
      amount: value(order, :order_amount_currency, :orderAmountCurrency, :amount),
      currency: value(order, :order_currency, :orderCurrency, :currency, :currency_code, :currencyCode),
      created_at: value(order, :created_at, :createdAt, :order_created_at_ms, :orderCreatedAtMs, :create_datetime, :createDatetime),
      paid_at: value(order, :paid_at, :paidAt, :order_paid_at_ms, :orderPaidAtMs, :paid_datetime, :paidDatetime),
      completed_at: value(order, :completed_at, :completedAt, :order_completed_at_ms, :orderCompletedAtMs),
      purchased_at: value(order, :purchased_at, :purchasedAt) || value(data_plan, :purchased_at, :purchasedAt),
      data_size_value: size_value,
      data_size_unit: size_unit,
      data_unlimited: value(sku, :data_size_is_unlimited, :dataSizeIsUnlimited, :is_unlimited),
      billing_period_days: value(sku, :billing_period_days, :billingPeriodDays, :billing_period, :billingPeriod) ||
        value(order, :billing_period_days, :billingPeriodDays),
      plan_status: value(data_plan, :plan_status, :planStatus, :status) || value(order, :plan_status, :planStatus),
      data_total_gb: value(data_plan, :data_total_gb, :dataTotalGb) || value(order, :data_total_gb, :dataTotalGb),
      data_used_gb: value(data_plan, :data_consumed_gb, :dataConsumedGb) || value(order, :data_consumed_gb, :dataConsumedGb, :data_size_used, :dataSizeUsed),
      data_remaining_gb: value(data_plan, :data_remaining_gb, :dataRemainingGb) || value(order, :data_remaining_gb, :dataRemainingGb),
      remaining_data_gb: value(data_plan, :data_remaining_gb, :dataRemainingGb),
      activate_before: value(data_plan, :activate_before, :activateBefore),
      activated_at: value(data_plan, :activated_at, :activatedAt) || value(order, :activated_at, :activatedAt, :actived_time, :activedTime),
      expires_at: value(data_plan, :expired_at, :expiredAt) || value(order, :expired_at, :expiredAt, :expired_time, :expiredTime)
    }.compact.slice(*ORDER_KEYS).transform_values { |item| scalar(item) }
  end

  # The upstream payload mixes shapes: `sku` is an object while `order_goods` is a
  # single-element array. Both describe the purchased SKU.
  def sku_source(order)
    direct = value(order, :sku)
    return direct if direct.is_a?(Hash)

    Array(value(order, :order_goods, :orderGoods)).first
  end

  def data_size(order, sku)
    megabytes = value(order, :data_size_mb, :dataSizeMb) || value(sku, :data_size_mb, :dataSizeMb)
    return [megabytes, 'MB'] if megabytes.present?

    gigabytes = value(order, :data_size_gb, :dataSizeGb) || value(sku, :data_size_gb, :dataSizeGb)
    gigabytes.present? ? [gigabytes, 'GB'] : [nil, nil]
  end

  # Verified against the live endpoint: an element carries product_id / product_name /
  # country_* and a skus array with data_size_* / price / sku_labels.
  def present_plan(raw)
    plan = hash(raw)
    {
      product_id: value(plan, :product_id, :productId),
      name: value(plan, :product_name, :productName, :name),
      country_code: value(plan, :country_code, :countryCode),
      country_name: value(plan, :country_url_name, :countryUrlName),
      image: value(plan, :country_image, :countryImage),
      skus: Array(value(plan, :skus)).first(MAX_ITEMS).map { |sku| present_sku(sku) }
    }.compact
  end

  def present_product(raw, fallback_id = nil)
    product = hash(raw)
    {
      product_id: value(product, :product_id, :productId) || fallback_id,
      name: value(product, :name, :product_name, :productName),
      country_code: value(product, :country_code, :countryCode),
      country_name: value(product, :country_url_name, :countryUrlName),
      image: value(product, :country_image, :countryImage, :background_image, :backgroundImage),
      from_price: value(product, :min_sku_price, :minSkuPrice),
      skus: Array(value(product, :skus)).first(MAX_ITEMS).map { |sku| present_sku(sku) }
    }.compact
  end

  def present_sku(raw)
    sku = hash(raw)
    # Upstream reports the size as 0 for unlimited SKUs, which reads as "0 GB" in a prompt.
    unlimited = value(sku, :data_size_is_unlimited, :dataSizeIsUnlimited)
    gigabytes = value(sku, :data_size_gb, :dataSizeGb)

    {
      sku_id: value(sku, :sku_id, :skuId, :id),
      name: value(sku, :sku_name, :skuName, :name, :product_name, :productName),
      data_size_value: unlimited ? nil : (gigabytes || value(sku, :data_size_mb, :dataSizeMb)),
      data_size_unit: unlimited ? nil : (gigabytes.present? ? 'GB' : 'MB'),
      data_unlimited: unlimited,
      billing_period_days: value(sku, :billing_period_days, :billingPeriodDays, :billing_period, :billingPeriod),
      price: value(sku, :price),
      labels: Array(value(sku, :sku_labels, :skuLabels)).first(MAX_ITEMS)
    }.compact.transform_values { |item| scalar(item) }
  end

  # --- Card building ---

  # The model picks the ids, so they are untrusted input: answer without calling upstream when
  # they are missing or not ids at all.
  def purchase_request_error(product_id, sku_ids)
    return 'product_id and one to five sku_ids are required.' if product_id.blank? || sku_ids.empty?
    return 'product_id and sku_ids must be numeric ids.' unless [product_id, *sku_ids].all? { |id| checkout_id?(id) }

    nil
  end

  # The message validator wants exactly these six keys, so `media_url` is present and empty
  # rather than omitted: the card is a fixed-size bubble and a country image of arbitrary aspect
  # ratio would size it. The title carries the destination.
  def purchase_card(product, sku, copy, primary:, params:)
    {
      title: product[:name].to_s,
      description: MobileChat::CardCopy.sanitize_description(primary ? param(params, :reason) : nil, copy['description']),
      media_url: '',
      badge: primary ? copy['primary'] : copy['alternative'],
      facts: purchase_facts(sku, copy),
      actions: [{
        type: 'link',
        text: MobileChat::CardCopy.sanitize_action_text(primary ? param(params, :label) : nil, copy['cta']),
        uri: checkout_uri(product[:product_id], sku[:sku_id])
      }]
    }
  end

  def purchase_cards(product, skus, params)
    copy = MobileChat::CardCopy.copy_for(client_locale)
    skus.each_with_index.map do |sku, index|
      purchase_card(product, sku, copy, primary: index.zero?, params: params)
    end
  end

  # The response is the product's own sku list, so an id the model invented or that belongs to a
  # different product simply is not found.
  def selected_skus(product, sku_ids)
    sku_ids.map { |id| Array(product[:skus]).find { |sku| sku[:sku_id].to_s == id } }
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

  def hash(value)
    value.is_a?(Hash) ? value.with_indifferent_access : {}.with_indifferent_access
  end

  def value(source, *keys)
    keys.each do |key|
      candidate = source[key]
      return candidate if candidate.present?
    end
    nil
  end

  # Strings reaching the prompt are truncated so one large field cannot flood the context.
  def scalar(item)
    item.is_a?(String) ? item.truncate(MAX_STRING) : item
  end
end

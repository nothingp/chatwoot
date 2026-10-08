# Business methods behind the Captain custom tools.
#
# Everything that couples a Chatwoot conversation to Novyro for tool calls lives in this one
# file: resolving the customer's credentials off the conversation, calling Novyro, and shaping
# the response for an LLM. The controller on top of it only authenticates the caller and
# dispatches by tool slug.
#
# These methods never raise on upstream failures. The caller is an LLM tool call, so every
# failure becomes a structured `{ ok: false, error: ... }` the model can read back to the
# customer. Missing *configuration* is the one exception: it raises NotConfigured, which the
# controller renders as a 500, because it is a deployment bug rather than a customer problem.
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

  # params is the model-supplied argument hash; its keys are not trusted.
  def call(tool_slug, params)
    case tool_slug.to_s
    when 'list_orders' then list_orders
    when 'get_order_details' then get_order_details(params)
    when 'recommend_plans' then recommend_plans(params)
    when 'search_products' then search_products(params)
    when 'get_product_details' then get_product_details(params)
    else { ok: false, error: "Unknown tool: #{tool_slug}" }
    end
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

    response = fetch_json(RECOMMENDATIONS_PATH, query: { country_code: country, billing_period: period })
    return response if response[:ok] == false

    plans = Array(response.dig(:data, 'recommendations'))
    { ok: true, count: plans.size, plans: plans.first(MAX_ITEMS).map { |plan| present_plan(plan) } }
  end

  def search_products(params)
    keyword = param(params, :keyword).to_s.strip
    return { ok: false, error: 'keyword is required.' } if keyword.blank?

    response = fetch_json(PRODUCT_SEARCH_PATH, query: { keyword: keyword })
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

    response = fetch_json(PRODUCT_DETAILS_PATH, query: { product_id: product_id })
    return response if response[:ok] == false

    product = response.dig(:data, 'product') || response[:data]
    return { ok: false, error: UPSTREAM_UNAVAILABLE } unless product.is_a?(Hash)

    { ok: true, product: present_product(product, product_id) }
  end

  private

  attr_reader :conversation

  def contact
    @contact ||= conversation.contact_inbox&.contact
  end

  # Written at session creation and refreshed on every new session (MobileChat::ContactCredentials).
  def member_token
    @member_token ||= contact&.custom_attributes&.dig('app_token').presence
  end

  # → { ok: true, data: Hash } | { ok: false, error: String }
  def fetch_json(path, query: {}, token: nil)
    url = MobileChat::Config.novyro_url(path)
    url = "#{url}?#{URI.encode_www_form(query)}" if query.present?

    headers = MobileChat::Config.novyro_headers
    headers['token'] = token if token.present?

    body = +''
    SafeFetch.fetch(
      url,
      headers: headers,
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
    {
      sku_id: value(sku, :sku_id, :skuId, :id),
      name: value(sku, :sku_name, :skuName, :name, :product_name, :productName),
      data_size_value: value(sku, :data_size_gb, :dataSizeGb) || value(sku, :data_size_mb, :dataSizeMb),
      data_size_unit: value(sku, :data_size_gb, :dataSizeGb).present? ? 'GB' : 'MB',
      data_unlimited: value(sku, :data_size_is_unlimited, :dataSizeIsUnlimited),
      billing_period_days: value(sku, :billing_period_days, :billingPeriodDays, :billing_period, :billingPeriod),
      price: value(sku, :price),
      labels: Array(value(sku, :sku_labels, :skuLabels)).first(MAX_ITEMS)
    }.compact.transform_values { |item| scalar(item) }
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

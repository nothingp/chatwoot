require 'uri'

class ContentAttributeValidator < ActiveModel::Validator
  ALLOWED_SELECT_ITEM_KEYS = [:title, :value, :description].freeze
  ALLOWED_CARD_ITEM_KEYS = [:title, :description, :media_url, :actions].freeze
  ALLOWED_CARD_ITEM_ACTION_KEYS = [:text, :type, :payload, :uri].freeze
  ALLOWED_FORM_ITEM_KEYS = [:type, :placeholder, :label, :name, :options, :default, :required, :pattern, :title, :pattern_error].freeze
  ALLOWED_ARTICLE_KEYS = [:title, :description, :link].freeze

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

  def validate(record)
    case record.content_type
    when 'input_select'
      validate_items!(record)
      validate_item_attributes!(record, ALLOWED_SELECT_ITEM_KEYS)
    when 'cards'
      if novyro_plan_group?(record)
        validate_novyro_plan_group!(record)
      else
        validate_items!(record)
        validate_item_attributes!(record, ALLOWED_CARD_ITEM_KEYS)
        validate_item_actions!(record)
      end
    when 'form'
      validate_items!(record)
      validate_item_attributes!(record, ALLOWED_FORM_ITEM_KEYS)
    when 'article'
      validate_items!(record)
      validate_item_attributes!(record, ALLOWED_ARTICLE_KEYS)
    end
  end

  private

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

    unless exact_hash_keys?(item, NOVYRO_PLAN_REQUIRED_ITEM_KEYS)
      record.errors.add(:content_attributes, 'contains invalid keys for Novyro plan items')
    end

    NOVYRO_PLAN_TEXT_LIMITS.slice(:title, :description, :badge).each do |key, maximum|
      validate_bounded_text!(record, item, key, maximum)
    end

    record.errors.add(:content_attributes, 'Novyro plan media_url must be empty.') unless attribute_value(item, :media_url) == ''

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

    validate_novyro_plan_action!(record, actions.first)
  end

  def validate_novyro_plan_action!(record, action)
    record.errors.add(:content_attributes, 'contains invalid keys for Novyro plan actions') unless exact_hash_keys?(action, NOVYRO_PLAN_ACTION_KEYS)
    record.errors.add(:content_attributes, 'Novyro plan action type must be link.') unless attribute_value(action, :type) == 'link'
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
    return false unless checkout_uri_shape?(uri)

    checkout_terms?(URI.decode_www_form(uri.query.to_s))
  rescue URI::InvalidURIError, ArgumentError
    false
  end

  # Anything the app will not hand to its own URL handler: another scheme, credentials in the url,
  # a fragment, or a path other than the checkout action.
  def checkout_uri_shape?(uri)
    uri.is_a?(URI::HTTP) && %w[http https].include?(uri.scheme) && uri.host.present? &&
      uri.userinfo.nil? && uri.fragment.nil? && uri.path == NOVYRO_PLAN_ACTION_PATH
  end

  def checkout_terms?(pairs)
    return false unless pairs.length == NOVYRO_PLAN_ACTION_QUERY_KEYS.length &&
                        pairs.map(&:first).sort == NOVYRO_PLAN_ACTION_QUERY_KEYS

    terms = pairs.to_h
    checkout_id?(terms['goods_id']) && checkout_id?(terms['sku_id']) &&
      NOVYRO_PLAN_CATALOG_ENVIRONMENTS.include?(terms['catalog_env'])
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
    return false unless value.is_a?(Hash)

    value.keys.map(&:to_s).sort == expected_keys.map(&:to_s).sort
  end

  def attribute_value(attributes, key)
    return unless attributes.is_a?(Hash)

    attributes.key?(key) ? attributes[key] : attributes[key.to_s]
  end

  def validate_items!(record)
    record.errors.add(:content_attributes, 'At least one item is required.') if record.items.blank?
    record.errors.add(:content_attributes, 'Items should be a hash.') if record.items.reject { |item| item.is_a?(Hash) }.present?
  end

  def validate_item_attributes!(record, valid_keys)
    item_keys = record.items.collect(&:keys).flatten.filter_map(&:to_sym)
    invalid_keys = item_keys - valid_keys
    record.errors.add(:content_attributes, "contains invalid keys for items : #{invalid_keys}") if invalid_keys.present?
  end

  def validate_item_actions!(record)
    if record.items.select { |item| item[:actions].blank? }.present?
      record.errors.add(:content_attributes, 'contains items missing actions') && return
    end

    validate_item_action_attributes!(record)
  end

  def validate_item_action_attributes!(record)
    item_action_keys = record.items.collect { |item| item[:actions].collect(&:keys) }
    invalid_keys = item_action_keys.flatten.compact.map(&:to_sym) - ALLOWED_CARD_ITEM_ACTION_KEYS
    record.errors.add(:content_attributes, "contains invalid keys for actions:  #{invalid_keys}") if invalid_keys.present?
  end
end

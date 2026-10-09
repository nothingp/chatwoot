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
  # Four pipes is the bridge's table rule (purchaseCards.js); fewer are ordinary punctuation.
  MIN_TABLE_PIPES = 4
  # The card is a purchase surface: a link, markdown or a table in text the model wrote is
  # something the customer cannot trust. Fall back to the shipped copy instead.
  #
  # A scheme is only a URI when a payload follows the colon: "data:text/html;base64,..." is one,
  # while "Data: 10 GB" and "Tel: +81 90 1234" are prose the customer should still read.
  SCHEME_LIKE = /(?:[a-z][a-z0-9+.-]*):\S/i
  # www. anywhere, or a bare domain sitting in the text as a single whitespace-free token.
  DOMAIN_LIKE = %r{(?:\A|[^\w.-])www\.|(?:\A|[^\w.-])(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/:?#]|\z)}i
  MARKDOWN_LIKE = /\]\(|^\s{0,3}\#{1,6}\s|^\s{0,3}(?:[-*+]\s|\d+[.)]\s)/i
  # A flag or a ZWJ sequence is one emoji however many codepoints it carries -- regional
  # indicators are not Extended_Pictographic -- so count grapheme clusters, not codepoints.
  EMOJI = /\p{Extended_Pictographic}|\p{Regional_Indicator}/
  # The language families the app splits, keyed the way the bridge does it: the qualifier that
  # selects a variant, plus what a bare language falls back to. zh carries no entry of its own --
  # every Chinese locale is one of the two scripts -- and pt is Brazilian unless it says pt_PT.
  FAMILY_LOCALES = {
    'zh' => { 'hant' => 'zh_Hant', 'tw' => 'zh_Hant', 'hk' => 'zh_Hant', 'mo' => 'zh_Hant', 'default' => 'zh_CN' },
    'pt' => { 'pt' => 'pt_PT', 'default' => 'pt_BR' },
    'es' => { 'mx' => 'es_MX' },
    'fr' => { 'ca' => 'fr_CA' }
  }.freeze
  # Legacy ISO codes the app never sends, but older clients did.
  LEGACY_LANGUAGE_ALIASES = { 'fil' => 'tl', 'iw' => 'he', 'in' => 'id', 'nb' => 'no', 'nn' => 'no' }.freeze
  # The languages the store serves a prefixed path for, spelled the way its own SUPPORTED_LOCALES
  # spells them. `en` is the unprefixed root, so it is listed but never yields a prefix.
  WEB_LOCALES = %w[
    en zh-CN zh-Hant ja ko es de fr ar ru uz ky hi id pt-BR it th tl ms vi tr es-MX bn fa
    pl uk hr nl cs fi sk ro sv he el hu da fr-CA ca no pt-PT pt
  ].freeze

  class << self
    # The dictionary is keyed by the app's own appLocale, and clients send the locale raw -- the
    # website ships a bare "pt" -- so it is canonicalized before the lookup, exactly as the
    # bridge did (localeCopy.js normalizes, then falls back exact -> language prefix -> en).
    def copy_for(locale)
      dictionaries[canonical_locale(locale)] || dictionaries[ENGLISH] ||
        raise(CustomExceptions::MobileChat::NotConfigured, 'MOBILE_CHAT_CARD_COPY_EN')
    end

    # The store's paths spell a language with hyphens (zh-CN) while the app writes it with an
    # underscore (zh_CN), so the same canonicalization the copy uses runs first. A language the
    # store does not serve falls back to the unprefixed root: a path it does not have would be a
    # 404 on a purchase surface.
    def web_locale_prefix(locale)
      code = canonical_locale(locale).tr('_', '-')
      return '' unless WEB_LOCALES.include?(code) && code != ENGLISH

      "/#{code}"
    end

    def sanitize_description(value, fallback)
      sanitize(value, fallback, MAX_DESCRIPTION)
    end

    def sanitize_action_text(value, fallback)
      sanitize(value, fallback, MAX_ACTION_TEXT)
    end

    def dictionaries
      @dictionaries ||= load_copies
    end

    private

    # Frozen all the way down: these strings back every card the process builds, so a caller
    # writing into one would corrupt the copy for every later card.
    def load_copies
      copies = YAML.load_file(COPY_PATH)
      copies.each_value { |copy| copy.each_value(&:freeze).freeze }.freeze
    end

    # Port of the bridge's normalizeLocale (mobileChat/language.js): the raw client value becomes
    # the appLocale the dictionary is keyed by. Without it a bare "pt" matches no Portuguese entry
    # and that customer reads the English card.
    def canonical_locale(locale)
      normalized = locale.to_s.strip.downcase.tr('-', '_')
      return ENGLISH if normalized.blank?

      canonical_map[normalized] || family_locale(normalized) || canonical_map[aliased_language(normalized)] || ENGLISH
    end

    # Keyed by the dictionary's own keys, so it cannot drift from the copy it serves.
    def canonical_map
      dictionaries.keys.index_by(&:downcase)
    end

    def family_locale(normalized)
      language, *qualifiers = parts(normalized)
      family = FAMILY_LOCALES[language]
      return unless family

      qualifier = qualifiers.find { |part| family.key?(part) }
      family[qualifier || 'default']
    end

    # A regional locale falls back to its bare language, through the legacy aliases (en_GB -> en,
    # de_DE -> de, fil -> tl); anything the dictionary does not carry is English.
    def aliased_language(normalized)
      language = parts(normalized).first
      LEGACY_LANGUAGE_ALIASES.fetch(language, language)
    end

    def parts(normalized)
      normalized.split('_').reject(&:empty?)
    end

    def sanitize(value, fallback, maximum)
      text = value.to_s.gsub(/[\u0000-\u001f\u007f-\u009f]/, ' ').squish
      return fallback if text.blank? || text.length > maximum
      return fallback if disallowed?(text)

      text
    end

    # What the model may not put on a purchase card: a link, markdown the renderer would not
    # agree on, a table, or more decoration than the bubble holds.
    def disallowed?(text)
      text.match?(SCHEME_LIKE) || text.match?(DOMAIN_LIKE) || text.match?(MARKDOWN_LIKE) ||
        text.count('|') >= MIN_TABLE_PIPES || too_many_emoji?(text)
    end

    def too_many_emoji?(text)
      text.scan(/\X/).count { |cluster| cluster.match?(EMOJI) } > MAX_EMOJI
    end
  end
end

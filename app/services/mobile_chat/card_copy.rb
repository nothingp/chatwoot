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
  URL_LIKE = %r{(?:https?|ftp|file|ws|wss|mailto|tel|sms|data|javascript):|(?:\A|[^\w.-])www\.|(?:\A|[^\w.-])(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/:?#]|\z)}i
  MARKDOWN_LIKE = %r{\]\(|^\s{0,3}\#{1,6}\s|^\s{0,3}(?:[-*+]\s|\d+[.)]\s)}i
  # A flag or a ZWJ sequence is one emoji however many codepoints it carries -- regional
  # indicators are not Extended_Pictographic -- so count grapheme clusters, not codepoints.
  EMOJI = /\p{Extended_Pictographic}|\p{Regional_Indicator}/

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
      return fallback if text.scan(/\X/).count { |cluster| cluster.match?(EMOJI) } > MAX_EMOJI

      text
    end
  end
end

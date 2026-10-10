class MobileChat::SessionStore
  class << self
    # The handoff ticket only grants a widget token, so it must not outlive it: both read the
    # same configured expiry (WIDGET_TOKEN_EXPIRY) and can therefore never drift.
    def ttl
      Widget::TokenService.expiry_days.days
    end

    def create(contact_inbox:, inbox:)
      session_id = SecureRandom.uuid
      Redis::Alfred.setex(
        key(session_id),
        { contact_inbox_id: contact_inbox.id, inbox_id: inbox.id }.to_json,
        ttl
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
      (Time.current + ttl).to_i * 1000
    end

    def key(session_id)
      format(Redis::RedisKeys::MOBILE_CHAT_SESSION, id: session_id)
    end
  end
end

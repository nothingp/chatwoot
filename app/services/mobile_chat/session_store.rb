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

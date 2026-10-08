class MobileChat::NovyroClient
  # Verified against the production host (app.novyapp.com/api): successful product
  # responses carry `code: 1` and auth failures carry `code: 401`. The public API docs
  # show `code: 0`, but that documents a different host — do not "fix" this back to 0,
  # it silently turns every verified member into an anonymous guest.
  SUCCESS_CODE = 1
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

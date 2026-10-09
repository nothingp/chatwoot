# Shared request handling for the endpoints the app and the website call on the mobile-chat
# channel. Both take the same two client identifiers and reject a malformed one the same way, and
# a missing deployment configuration is an operator error either way.
class Public::Api::V1::MobileChat::BaseController < PublicController
  UUID_V4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  rescue_from CustomExceptions::MobileChat::NotConfigured, with: :render_error_response

  private

  def uuid_v4?(value)
    UUID_V4.match?(value.to_s)
  end

  def render_bad_request(message)
    render json: { error: message }, status: :bad_request
  end
end

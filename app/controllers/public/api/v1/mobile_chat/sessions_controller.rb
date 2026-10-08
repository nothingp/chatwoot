class Public::Api::V1::MobileChat::SessionsController < PublicController
  UUID_V4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  rescue_from CustomExceptions::MobileChat::NotConfigured, with: :render_error_response

  def create
    return render_bad_request('installationId must be a UUID v4') unless uuid_v4?(params[:installationId])
    return render_bad_request('anonymousProfileId must be a UUID v4') unless uuid_v4?(params[:anonymousProfileId])

    identity = identity_resolver.perform
    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      contact_attributes: identity.contact_attributes,
      source_id: identity.identifier,
      hmac_verified: identity.token.present?
    ).perform

    MobileChat::ContactCredentials.sync(contact_inbox.contact, identity.token)

    render json: session_response(MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox))
  end

  private

  def identity_resolver
    MobileChat::IdentityResolver.new(
      token: request.headers['token'],
      installation_id: params[:installationId],
      anonymous_profile_id: params[:anonymousProfileId]
    )
  end

  # source_id must stay stable: ContactInboxWithContactBuilder looks the contact inbox up by
  # source_id, and conversations hang off the contact inbox. Using the identifier keeps a
  # returning customer in the same conversation history instead of starting from scratch.
  def inbox
    @inbox ||= MobileChat::Config.inbox
  end

  def uuid_v4?(value)
    UUID_V4.match?(value.to_s)
  end

  def render_bad_request(message)
    render json: { error: message }, status: :bad_request
  end

  def session_response(session_id)
    {
      ok: true,
      chatUrl: "#{MobileChat::Config.frontend_url}/mobile-chat?session=#{session_id}",
      expiresAt: MobileChat::SessionStore.expires_at,
      identityCookieScope: {
        origin: MobileChat::Config.frontend_url,
        path: '/',
        conversationCookieName: 'cw_conversation',
        userCookieName: "cw_user_#{inbox.channel.website_token}"
      },
      identityContinuity: { confirmed: false }
    }
  end
end

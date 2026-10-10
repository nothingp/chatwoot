class Public::Api::V1::MobileChat::SessionsController < Public::Api::V1::MobileChat::BaseController
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

    MobileChat::ContactCredentials.sync(contact_inbox.contact, identity, session: session_attributes)

    render json: session_response(contact_inbox, MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox))
  end

  private

  # The two clients disagree on the locale key: the website sends `locale`, the app sends
  # `appLocale`. Everything else keeps the name both of them use.
  def session_attributes
    {
      locale: params[:locale].presence || params[:appLocale].presence,
      platform: params[:platform],
      catalog_environment: params[:catalogEnvironment],
      currency: params[:currency]
    }
  end

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

  def session_response(contact_inbox, session_id)
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
      identityContinuity: identity_continuity(contact_inbox)
    }
  end

  # The client stores this key and sends it back on the next session, so it can tell a returning
  # visitor from a fresh one -- and it will not ask for an unread count without one. Answering
  # `confirmed: false` with no key left that badge permanently blank, because the request was never
  # made rather than made and rejected.
  #
  # Derived from the contact inbox rather than stored, so the same visitor always answers the same
  # key; the HMAC keeps it unforgeable without a second table to keep in step.
  def identity_continuity(contact_inbox)
    key = continuity_key(contact_inbox)
    { confirmed: params[:identityContinuityKey].to_s == key, key: key }
  end

  def continuity_key(contact_inbox)
    digest = OpenSSL::HMAC.digest('SHA256', Rails.application.secret_key_base, "mobile-chat-continuity:#{contact_inbox.id}")
    "cs1_#{Base64.urlsafe_encode64(digest, padding: false)}"
  end
end

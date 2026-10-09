# The unread badge the website draws on its customer-support button.
#
# Mirrors the widget's own count (widget store/modules/conversation/getters.js): the outgoing
# messages the customer has not seen since the panel last reported itself as seen. The client
# treats any failure as "no badge", so a visitor with no conversation at all answers 0 rather than
# an error -- there is nothing for them to have missed, which is not a guess.
class Public::Api::V1::MobileChat::UnreadsController < Public::Api::V1::MobileChat::BaseController
  # The client's schema refuses a count above this, and a rejected response is no badge at all, so
  # a very long conversation is capped instead of dropped.
  MAX_UNREAD_COUNT = 1_000

  def create
    return render_bad_request('installationId must be a UUID v4') unless uuid_v4?(params[:installationId])
    return render_bad_request('anonymousProfileId must be a UUID v4') unless uuid_v4?(params[:anonymousProfileId])

    render json: { ok: true, unreadCount: unread_count }
  end

  private

  # This call carries no token header: the website identifies a visitor by the same guest
  # identifier it opened the session with, and a badge is not worth an upstream member lookup.
  def identity
    @identity ||= MobileChat::IdentityResolver.new(
      token: request.headers['token'],
      installation_id: params[:installationId],
      anonymous_profile_id: params[:anonymousProfileId]
    ).perform
  end

  def contact_inbox
    @contact_inbox ||= ::ContactInbox.find_by(inbox: MobileChat::Config.inbox, source_id: identity.identifier)
  end

  def unread_count
    return 0 if contact_inbox.blank?

    count = contact_inbox.conversations.sum { |conversation| unread_in(conversation) }
    [count, MAX_UNREAD_COUNT].min
  end

  # A customer who has never opened the panel has seen nothing, so every outgoing message counts.
  def unread_in(conversation)
    messages = conversation.messages.where(message_type: :outgoing, private: false)
    seen_at = conversation.contact_last_seen_at
    messages = messages.where('created_at > ?', seen_at) if seen_at.present?
    messages.count
  end
end

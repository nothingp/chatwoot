class MobileChatController < ActionController::Base
  layout false

  # Renders nothing itself: it only builds the widget token and hands the browser over to
  # the stock widget, which is why neither widgets/show.html.erb nor the widget app change.
  def show
    chat_session = MobileChat::SessionStore.read(params[:session])
    return render_expired if chat_session.blank?

    inbox = ::Inbox.find_by(id: chat_session['inbox_id'])
    contact_inbox = ::ContactInbox.find_by(id: chat_session['contact_inbox_id'])
    return render_expired if inbox.blank? || contact_inbox.blank?

    # The widget applies this parameter on top of the account locale, so the panel's chrome follows
    # the locale the session recorded on the contact. A blank value is omitted rather than sent empty,
    # which leaves the widget's normal resolution alone.
    # cw_handoff marks this entry as ours: the widget is embedded without the official SDK here, so
    # it has to fetch the conversation history itself instead of waiting for the config-set handshake.
    redirect_to widget_path({
      website_token: inbox.channel.website_token,
      cw_conversation: widget_token(inbox, contact_inbox),
      cw_handoff: '1',
      # The contact can be gone while its contact inbox is not: the delete is async, and the widget
      # self-heals by creating a fresh contact, so this must not raise in that window.
      locale: contact_inbox.contact&.custom_attributes&.dig('locale')
    }.compact_blank)
  end

  private

  def render_expired
    # The 410 renders inside the customer-facing iframe, so it has to stay frameable.
    response.headers.delete('X-Frame-Options')
    render :expired, status: :gone
  end

  def widget_token(inbox, contact_inbox)
    Widget::TokenService.new(
      payload: { source_id: contact_inbox.source_id, inbox_id: inbox.id }
    ).generate_token
  end
end

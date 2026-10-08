require 'rails_helper'

RSpec.describe 'Mobile chat handoff', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  it 'redirects to the widget with a conversation token for the stored contact inbox' do
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)

    get '/mobile-chat', params: { session: session_id }

    expect(response).to have_http_status(:found)
    location = URI.parse(response.location)
    query = URI.decode_www_form(location.query).to_h
    expect(location.path).to eq('/widget')
    expect(query['website_token']).to eq(inbox.channel.website_token)

    payload = Widget::TokenService.new(token: query['cw_conversation']).decode_token
    expect(payload[:source_id]).to eq(contact_inbox.source_id)
    expect(payload[:inbox_id]).to eq(inbox.id)
  end

  it 'renders 410 for an unknown session' do
    get '/mobile-chat', params: { session: SecureRandom.uuid }

    expect(response).to have_http_status(:gone)
  end

  it 'renders 410 for a blank session' do
    get '/mobile-chat'

    expect(response).to have_http_status(:gone)
  end

  it 'renders 410 when the session outlived its contact inbox' do
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)
    contact_inbox.destroy!

    get '/mobile-chat', params: { session: session_id }

    expect(response).to have_http_status(:gone)
  end

  it 'keeps the expired page embeddable in a cross-origin iframe' do
    get '/mobile-chat', params: { session: SecureRandom.uuid }

    expect(response.headers['X-Frame-Options']).to be_nil
  end

  it 'hands the pre-created contact to the widget instead of creating a new one' do
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)

    get '/mobile-chat', params: { session: session_id }
    get response.location

    expect(response).to have_http_status(:ok)
    expect(Contact.count).to eq(1)
    expect(ContactInbox.count).to eq(1)
  end
end

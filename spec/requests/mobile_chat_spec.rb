require 'rails_helper'

RSpec.describe 'Mobile chat handoff', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:installation_id) { '3f2504e0-4f89-41d3-9a0c-0305e82c3301' }
  let(:anonymous_profile_id) { '9c858901-8a57-4791-81fe-4c455b099bc9' }
  let(:frontend_url) { 'https://chat.example.com' }
  let(:guest_identifier) { "guest_#{installation_id}_#{anonymous_profile_id}" }

  before do
    create(:installation_config, name: 'MOBILE_CHAT_INBOX_ID', value: inbox.id)
    create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'https://api.example.com/api')
    create(:installation_config, name: 'NOVYRO_USER_INFO_PATH', value: '/v2/esim/user/info')
    create(:installation_config, name: 'NOVYRO_API_KEY', value: 'service-key')
    create(:installation_config, name: 'NOVYRO_SITE_ID', value: '10000')

    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('api.example.com').and_return(['93.184.216.34'])
  end

  it 'carries the guest identity from the session POST through to the widget' do
    payload = { installationId: installation_id, anonymousProfileId: anonymous_profile_id }

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    expect(response).to have_http_status(:ok)
    chat_url = URI.parse(response.parsed_body['chatUrl'])

    get chat_url.path, params: { session: URI.decode_www_form(chat_url.query).to_h['session'] }
    get response.location

    expect(response).to have_http_status(:ok)
    expect(Contact.last.identifier).to eq(guest_identifier)
    expect(Contact.count).to eq(1)
    expect(ContactInbox.count).to eq(1)
  end

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

  it 'forwards the locale recorded on the contact to the widget' do
    contact.update!(custom_attributes: { 'locale' => 'zh_CN' })
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)

    get '/mobile-chat', params: { session: session_id }

    expect(response).to have_http_status(:found)
    query = URI.decode_www_form(URI.parse(response.location).query).to_h
    expect(query['locale']).to eq('zh_CN')
  end

  it 'omits the locale parameter when the contact has none' do
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)

    get '/mobile-chat', params: { session: session_id }

    expect(response).to have_http_status(:found)
    query = URI.decode_www_form(URI.parse(response.location).query).to_h
    expect(query).not_to have_key('locale')
  end

  it 'still redirects when the session outlived its contact' do
    session_id = MobileChat::SessionStore.create(contact_inbox: contact_inbox, inbox: inbox)
    contact.destroy!

    get '/mobile-chat', params: { session: session_id }

    expect(response).to have_http_status(:found)
    query = URI.decode_www_form(URI.parse(response.location).query).to_h
    expect(query).not_to have_key('locale')
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

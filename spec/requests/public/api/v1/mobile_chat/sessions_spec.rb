require 'rails_helper'

RSpec.describe 'Public mobile chat session API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:installation_id) { '3f2504e0-4f89-41d3-9a0c-0305e82c3301' }
  let(:anonymous_profile_id) { '9c858901-8a57-4791-81fe-4c455b099bc9' }
  let(:frontend_url) { 'https://chat.example.com' }
  let(:user_info_url) { 'https://api.example.com/api/v2/esim/user/info' }
  let(:payload) do
    {
      platform: 'web',
      locale: 'zh_CN',
      systemLanguage: 'zh-CN',
      catalogEnvironment: 'prod',
      entryPoint: 'web_home_buy_esim',
      appVersion: 'web-0.1.0',
      installationId: installation_id,
      anonymousProfileId: anonymous_profile_id,
      resetChatIdentity: false
    }
  end
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

  it 'returns exactly the strict frontend response contract' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.keys).to contain_exactly('ok', 'chatUrl', 'expiresAt', 'identityCookieScope', 'identityContinuity')
    expect(body['ok']).to be(true)
    expect(body['identityContinuity']).to eq('confirmed' => false)
    expect(body['identityCookieScope']).to eq(
      'origin' => frontend_url,
      'path' => '/',
      'conversationCookieName' => 'cw_conversation',
      'userCookieName' => "cw_user_#{inbox.channel.website_token}"
    )
  end

  it 'returns a chat url that is exactly chatOrigin/mobile-chat with one session param' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    chat_url = URI.parse(response.parsed_body['chatUrl'])
    query = URI.decode_www_form(chat_url.query)

    expect(chat_url.origin).to eq(frontend_url)
    expect(chat_url.path).to eq('/mobile-chat')
    expect(query.map(&:first)).to eq(['session'])
    expect(query.first.last).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
  end

  it 'returns expiresAt as milliseconds inside the configured widget token expiry window' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    now = Time.current.to_i * 1000
    expect(response.parsed_body['expiresAt']).to be_a(Integer)
    expect(response.parsed_body['expiresAt']).to be > now + 1_000
    expect(response.parsed_body['expiresAt']).to be <= now + (Widget::TokenService.expiry_days.days.to_i * 1000)
  end

  it 'creates one guest contact and reuses the same contact inbox on the next call' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      expect do
        2.times { post '/public/api/v1/mobile_chat/session', params: payload, as: :json }
      end.to change(ContactInbox, :count).by(1)
    end

    expect(Contact.last.identifier).to eq(guest_identifier)
    expect(ContactInbox.last.hmac_verified).to be(false)
  end

  it 'records the session values on the contact for later tools' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    expect(Contact.last.custom_attributes).to include(
      'locale' => 'zh_CN',
      'platform' => 'web',
      'catalog_environment' => 'prod'
    )
  end

  it 'accepts the app spelling of the locale' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload.except(:locale).merge(appLocale: 'ja_JP'), as: :json
    end

    expect(Contact.last.custom_attributes['locale']).to eq('ja_JP')
  end

  it 'identifies a verified member and stores the app token' do
    stub_request(:get, user_info_url).to_return(
      status: 200,
      body: { code: 1, msg: 'success',
              data: { id: 1001, nickname: 'Zhang San', email: 'member@example.com' } }.to_json
    )

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'member-token' }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(Contact.last.identifier).to eq('member_1001')
    expect(Contact.last.name).to eq('Zhang San')
    expect(Contact.last.custom_attributes['app_token']).to eq('member-token')
    expect(ContactInbox.last.hmac_verified).to be(true)
  end

  it 'refreshes the app token when a member returns with a new one' do
    allow(MobileChat::NovyroClient).to receive(:new).with(token: 'first-token').and_return(
      instance_double(MobileChat::NovyroClient, user_info: { 'id' => 1001, 'nickname' => 'Zhang San' })
    )
    allow(MobileChat::NovyroClient).to receive(:new).with(token: 'second-token').and_return(
      instance_double(MobileChat::NovyroClient, user_info: { 'id' => 1001, 'nickname' => 'Zhang San' })
    )

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'first-token' }, as: :json
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'second-token' }, as: :json
    end

    expect(Contact.count).to eq(1)
    expect(Contact.last.custom_attributes['app_token']).to eq('second-token')
  end

  it 'falls back to a guest session when the business API rejects the token' do
    stub_request(:get, user_info_url).to_return(status: 401, body: { code: 401, msg: 'unauthorized' }.to_json)

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'stale-token' }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(Contact.last.identifier).to eq(guest_identifier)
    expect(Contact.last.custom_attributes).not_to have_key('app_token')
    expect(ContactInbox.last.hmac_verified).to be(false)
  end

  it 'falls back to a guest session when the business API times out' do
    stub_request(:get, user_info_url).to_timeout

    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload, headers: { 'token' => 'member-token' }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(Contact.last.identifier).to eq(guest_identifier)
    expect(ContactInbox.last.hmac_verified).to be(false)
  end

  it 'rejects a malformed installation id without creating a contact' do
    expect do
      post '/public/api/v1/mobile_chat/session', params: payload.merge(installationId: 'not-a-uuid'), as: :json
    end.not_to(change(Contact, :count))

    expect(response).to have_http_status(:bad_request)
  end

  it 'rejects a malformed anonymous profile id' do
    post '/public/api/v1/mobile_chat/session', params: payload.merge(anonymousProfileId: 'not-a-uuid'), as: :json

    expect(response).to have_http_status(:bad_request)
  end

  it 'returns 500 when the mobile chat inbox is not configured' do
    InstallationConfig.where(name: 'MOBILE_CHAT_INBOX_ID').delete_all

    post '/public/api/v1/mobile_chat/session', params: payload, as: :json

    expect(response).to have_http_status(:internal_server_error)
  end

  it 'returns 500 when FRONTEND_URL is not configured' do
    with_modified_env(FRONTEND_URL: nil) do
      post '/public/api/v1/mobile_chat/session', params: payload, as: :json
    end

    expect(response).to have_http_status(:internal_server_error)
  end

  it 'answers the CORS preflight for the session endpoint' do
    options '/public/api/v1/mobile_chat/session',
            headers: { 'Origin' => 'https://app.example.com', 'Access-Control-Request-Method' => 'POST' }

    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
  end

  it 'sends the CORS header on the actual POST' do
    with_modified_env(FRONTEND_URL: frontend_url) do
      post '/public/api/v1/mobile_chat/session', params: payload,
                                               headers: { 'Origin' => 'https://app.example.com' }, as: :json
    end

    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
  end
end

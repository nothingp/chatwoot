require 'rails_helper'

RSpec.describe 'Internal captain tools endpoint', type: :request do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:internal_token) { 'internal-secret' }
  let(:headers) do
    {
      'X-Internal-Token' => internal_token,
      'X-Chatwoot-Conversation-Id' => conversation.id.to_s,
      'X-Chatwoot-Account-Id' => account.id.to_s,
      'X-Chatwoot-Tool-Slug' => 'list_orders'
    }
  end

  before do
    create(:installation_config, name: 'MOBILE_CHAT_INTERNAL_TOOL_TOKEN', value: internal_token)
  end

  it 'dispatches the tool slug for the given conversation' do
    allow(MobileChat::CaptainToolkit).to receive(:new).with(conversation).and_return(
      instance_double(MobileChat::CaptainToolkit, call: { ok: true, count: 0, orders: [] })
    )

    post '/internal/captain_tools', params: {}, as: :json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('ok' => true, 'count' => 0, 'orders' => [])
  end

  it 'rejects a request without the internal token' do
    post '/internal/captain_tools', params: {}, as: :json, headers: headers.except('X-Internal-Token')

    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects a request with the wrong internal token' do
    post '/internal/captain_tools', params: {}, as: :json,
                                   headers: headers.merge('X-Internal-Token' => 'not-the-secret')

    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not read a conversation belonging to another account' do
    other_conversation = create(:conversation)

    post '/internal/captain_tools', params: {}, as: :json,
                                   headers: headers.merge('X-Chatwoot-Conversation-Id' => other_conversation.id.to_s)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('ok' => false, 'error' => 'Conversation not found.')
  end

  it 'reports an unknown tool slug without touching Novyro' do
    post '/internal/captain_tools', params: {}, as: :json,
                                   headers: headers.merge('X-Chatwoot-Tool-Slug' => 'not_a_tool')

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['ok']).to be(false)
    expect(response.parsed_body['error']).to include('Unknown tool')
  end
end

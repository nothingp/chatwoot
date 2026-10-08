require 'rails_helper'

RSpec.describe MobileChat::NovyroClient do
  let(:user_info_url) { 'https://api.example.com/api/v2/esim/user/info' }
  let(:client) { described_class.new(token: 'member-token') }

  before do
    create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'https://api.example.com/api')
    create(:installation_config, name: 'NOVYRO_USER_INFO_PATH', value: '/v2/esim/user/info')
    create(:installation_config, name: 'NOVYRO_API_KEY', value: 'service-key')
    create(:installation_config, name: 'NOVYRO_SITE_ID', value: '10000')

    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('api.example.com').and_return(['93.184.216.34'])
  end

  it 'sends the app token together with the service credentials' do
    request = stub_request(:get, user_info_url)
              .with(headers: { 'token' => 'member-token', 'x-api-key' => 'service-key', 'site-id' => '10000' })
              .to_return(status: 200, body: { code: 0, msg: 'success',
                                              data: { id: 1001, nickname: 'Zhang San', email: 'user@example.com' } }.to_json)

    expect(client.user_info).to eq('id' => 1001, 'nickname' => 'Zhang San', 'email' => 'user@example.com')
    expect(request).to have_been_requested
  end

  it 'returns nil for a non-success business code' do
    stub_request(:get, user_info_url).to_return(status: 200, body: { code: 401, msg: 'unauthorized' }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil for a string success code' do
    stub_request(:get, user_info_url).to_return(status: 200, body: { code: '0', data: { id: 1001 } }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the payload carries no member id' do
    stub_request(:get, user_info_url).to_return(status: 200, body: { code: 0, data: { nickname: 'Zhang San' } }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil when data is not an object' do
    stub_request(:get, user_info_url).to_return(status: 200, body: { code: 0, data: nil }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the upstream refuses the token' do
    stub_request(:get, user_info_url).to_return(status: 401, body: { code: 401 }.to_json)

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the upstream fails' do
    stub_request(:get, user_info_url).to_return(status: 500, body: 'boom')

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the upstream times out' do
    stub_request(:get, user_info_url).to_timeout

    expect(client.user_info).to be_nil
  end

  it 'returns nil when the body is not JSON' do
    stub_request(:get, user_info_url).to_return(status: 200, body: '<html>nope</html>')

    expect(client.user_info).to be_nil
  end

  it 'propagates a missing configuration instead of degrading to anonymous' do
    InstallationConfig.where(name: 'NOVYRO_API_KEY').delete_all

    expect { client.user_info }.to raise_error(CustomExceptions::MobileChat::NotConfigured)
  end
end

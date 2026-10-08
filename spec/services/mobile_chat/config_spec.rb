require 'rails_helper'

RSpec.describe MobileChat::Config do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  before do
    create(:installation_config, name: 'MOBILE_CHAT_INBOX_ID', value: inbox.id)
    create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'https://api.example.com/api')
    create(:installation_config, name: 'NOVYRO_USER_INFO_PATH', value: '/v2/esim/user/info')
    create(:installation_config, name: 'NOVYRO_API_KEY', value: 'service-key')
    create(:installation_config, name: 'NOVYRO_SITE_ID', value: '10000')
  end

  describe '.inbox' do
    it 'returns the configured inbox' do
      expect(described_class.inbox).to eq(inbox)
    end

    it 'raises with the config name when the inbox id is blank' do
      InstallationConfig.where(name: 'MOBILE_CHAT_INBOX_ID').delete_all

      expect { described_class.inbox }
        .to raise_error(CustomExceptions::MobileChat::NotConfigured, /MOBILE_CHAT_INBOX_ID/)
    end

    it 'raises with the config name when the configured inbox no longer exists' do
      inbox.destroy!

      expect { described_class.inbox }
        .to raise_error(CustomExceptions::MobileChat::NotConfigured, /MOBILE_CHAT_INBOX_ID/)
    end
  end

  describe '.frontend_url' do
    it 'returns FRONTEND_URL' do
      with_modified_env(FRONTEND_URL: 'https://chat.example.com') do
        expect(described_class.frontend_url).to eq('https://chat.example.com')
      end
    end

    it 'raises with the env var name when FRONTEND_URL is blank' do
      with_modified_env(FRONTEND_URL: nil) do
        expect { described_class.frontend_url }
          .to raise_error(CustomExceptions::MobileChat::NotConfigured, /FRONTEND_URL/)
      end
    end

    it 'strips a trailing slash so the origin matches the browser canonical origin' do
      with_modified_env(FRONTEND_URL: 'https://chat.example.com/') do
        expect(described_class.frontend_url).to eq('https://chat.example.com')
      end
    end
  end

  describe '.novyro_user_info_url' do
    it 'joins the base url with the configured path' do
      expect(described_class.novyro_user_info_url).to eq('https://api.example.com/api/v2/esim/user/info')
    end

    it 'joins a base url with a trailing slash without doubling the separator' do
      InstallationConfig.where(name: 'NOVYRO_API_BASE_URL').delete_all
      create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'https://api.example.com/api/')

      expect(described_class.novyro_user_info_url).to eq('https://api.example.com/api/v2/esim/user/info')
    end

    it 'raises with the config name when the base url is not absolute' do
      InstallationConfig.where(name: 'NOVYRO_API_BASE_URL').delete_all
      create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'api.example.com/api')

      expect { described_class.novyro_user_info_url }
        .to raise_error(CustomExceptions::MobileChat::NotConfigured, /NOVYRO_API_BASE_URL/)
    end
  end

  describe '.novyro_headers' do
    it 'returns the service credential headers' do
      expect(described_class.novyro_headers).to eq(
        'Accept' => 'application/json',
        'x-api-key' => 'service-key',
        'site-id' => '10000'
      )
    end

    it 'raises with the config name when the api key is missing' do
      InstallationConfig.where(name: 'NOVYRO_API_KEY').delete_all

      expect { described_class.novyro_headers }
        .to raise_error(CustomExceptions::MobileChat::NotConfigured, /NOVYRO_API_KEY/)
    end
  end
end

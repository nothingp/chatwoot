require 'rails_helper'

# The app's contract sample, verbatim from
# esimgo-mobile/test/chatwoot_client_models_test.dart ("parses the complete Novyro plan-group
# response contract"). If this stops validating, the app stops rendering plan cards.
RSpec.describe 'novyro plan group contract' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) do
    build(:message, account: account, inbox: inbox, conversation: conversation,
                    content_type: :cards, content: '久等了。您的 eSIM 在这里。',
                    content_attributes: {
                      'variant' => 'novyro_plan_group',
                      'items' => [{
                        'title' => 'Japan',
                        'description' => '7天日本专属行程，10GB总量。',
                        'media_url' => '',
                        'badge' => '最佳匹配',
                        'facts' => [
                          { 'icon' => 'wifi', 'label' => '流量', 'value' => '10 GB' },
                          { 'icon' => 'calendar', 'label' => '有效期', 'value' => '7 天' },
                          { 'icon' => 'wallet', 'label' => '价格', 'value' => 'USD 16.99' }
                        ],
                        'actions' => [{
                          'type' => 'link',
                          'text' => '日本 7日 10GB 总量套餐',
                          'uri' => 'https://support-api.esingo.app/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod'
                        }]
                      }]
                    })
  end

  it 'accepts the sample the app parses' do
    expect(message).to be_valid
  end
end

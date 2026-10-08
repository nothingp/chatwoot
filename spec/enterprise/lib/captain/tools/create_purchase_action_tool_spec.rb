require 'rails_helper'

RSpec.describe Captain::Tools::CreatePurchaseActionTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) do
    create(:contact, account: account, identifier: 'member_12345',
                     custom_attributes: { 'app_token' => 'member-token', 'locale' => 'en',
                                          'currency' => 'USD', 'catalog_environment' => 'prod' })
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:tool) { described_class.new(assistant) }
  # The repo's tool specs build the context as a bare Struct (see handoff_tool_spec.rb).
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id } }) }
  let(:toolkit) { instance_double(MobileChat::CaptainToolkit) }
  let(:cards) do
    [{
      title: 'Japan', description: 'Verified plan option.', media_url: '', badge: 'Best match',
      facts: [{ icon: 'wifi', label: 'Data', value: '10 GB' }],
      actions: [{ type: 'link', text: 'View plan',
                  uri: 'https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod' }]
    }]
  end

  before { allow(MobileChat::CaptainToolkit).to receive(:new).and_return(toolkit) }

  it 'posts the cards as a novyro plan group message' do
    allow(toolkit).to receive(:purchase_actions).and_return({ ok: true, cards: cards })

    result = tool.perform(tool_context, product_id: '13', sku_ids: %w[13055], reason: 'x', label: 'y')

    message = conversation.messages.last
    expect(message.content_type).to eq('cards')
    expect(message.content).to eq('Japan')
    expect(message.content_attributes['variant']).to eq('novyro_plan_group')
    # content_attributes is a jsonb-backed store: symbol keys come back as strings, and the items
    # are an array, so each card is stringified on its own.
    expect(message.content_attributes['items']).to eq(cards.map(&:deep_stringify_keys))
    expect(result).to include('Posted 1 plan card')
  end

  it 'returns the toolkit error instead of posting when the skus do not check out' do
    allow(toolkit).to receive(:purchase_actions).and_return({ ok: false, error: 'Those sku_ids are not part of that product.' })

    result = tool.perform(tool_context, product_id: '13', sku_ids: %w[99999], reason: 'x', label: 'y')

    expect(result).to include('not part of that product')
    expect(conversation.messages.count).to eq(0)
  end
end

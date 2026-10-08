require 'rails_helper'

RSpec.describe ContentAttributeValidator do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:card) do
    {
      title: 'Japan',
      description: 'Verified plan option.',
      media_url: '',
      badge: 'Best match',
      facts: [
        { icon: 'wifi', label: 'Data', value: '10 GB' },
        { icon: 'calendar', label: 'Validity', value: '7 days' },
        { icon: 'wallet', label: 'Price', value: 'USD 16.99' }
      ],
      actions: [{
        type: 'link',
        text: 'View plan',
        uri: 'https://support.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod'
      }]
    }
  end
  let(:items) { [card] }
  let(:message) do
    build(:message, account: account, inbox: inbox, conversation: conversation,
                    content_type: :cards, content: 'Japan',
                    content_attributes: { variant: 'novyro_plan_group', items: items })
  end

  # `let` has no setter, so an example that needs different items rebuilds the attribute hash.
  def plan_group(items)
    { variant: 'novyro_plan_group', items: items }
  end

  it 'accepts a plan group card' do
    expect(message).to be_valid
  end

  it 'accepts up to five items' do
    message.content_attributes = plan_group(Array.new(5) { card })

    expect(message).to be_valid
  end

  it 'rejects an unknown top level key' do
    message.content_attributes = plan_group(items).merge(extra: 1)

    expect(message).not_to be_valid
  end

  it 'rejects a missing variant' do
    message.content_attributes = { items: items }

    expect(message).not_to be_valid
  end

  it 'rejects more than five items' do
    message.content_attributes = plan_group(Array.new(6) { card })

    expect(message).not_to be_valid
  end

  it 'rejects an item without a badge' do
    message.content_attributes = plan_group([card.except(:badge)])

    expect(message).not_to be_valid
  end

  it 'rejects an item without facts' do
    message.content_attributes = plan_group([card.except(:facts)])

    expect(message).not_to be_valid
  end

  it 'rejects a nonempty media_url' do
    message.content_attributes = plan_group([card.merge(media_url: 'https://cdn.example.com/jp.svg')])

    expect(message).not_to be_valid
  end

  it 'accepts a card with an https country image' do
    message.content_attributes = plan_group([card.merge(country_image: 'https://admin.esimgo.site/upload/attachment/image/10000/202601/01/JP.svg')])

    expect(message).to be_valid
  end

  it 'rejects an http country image' do
    message.content_attributes = plan_group([card.merge(country_image: 'http://admin.esimgo.site/upload/attachment/image/10000/202601/01/JP.svg')])

    expect(message).not_to be_valid
  end

  it 'rejects a country image that is not a url' do
    message.content_attributes = plan_group([card.merge(country_image: '/upload/attachment/image/JP.svg')])

    expect(message).not_to be_valid
  end

  it 'rejects an empty country image' do
    message.content_attributes = plan_group([card.merge(country_image: '')])

    expect(message).not_to be_valid
  end

  it 'rejects a country image carrying a fragment' do
    message.content_attributes = plan_group([card.merge(country_image: 'https://cdn.example.com/jp.svg#flag')])

    expect(message).not_to be_valid
  end

  it 'rejects an unknown fact icon' do
    message.content_attributes = plan_group([card.merge(facts: [{ icon: 'star', label: 'Data', value: '10 GB' }])])

    expect(message).not_to be_valid
  end

  it 'rejects more than three facts' do
    facts = card[:facts] + [{ icon: 'wifi', label: 'Extra', value: 'x' }]
    message.content_attributes = plan_group([card.merge(facts: facts)])

    expect(message).not_to be_valid
  end

  it 'rejects an empty fact list' do
    message.content_attributes = plan_group([card.merge(facts: [])])

    expect(message).not_to be_valid
  end

  it 'rejects an item with two actions' do
    message.content_attributes = plan_group([card.merge(actions: card[:actions] + card[:actions])])

    expect(message).not_to be_valid
  end

  it 'rejects a postback action' do
    action = card[:actions].first.merge(type: 'postback')
    message.content_attributes = plan_group([card.merge(actions: [action])])

    expect(message).not_to be_valid
  end

  it 'rejects a checkout uri without the catalog environment' do
    action = card[:actions].first.merge(uri: 'https://support.example.com/app-actions/checkout?goods_id=13&sku_id=13055')
    message.content_attributes = plan_group([card.merge(actions: [action])])

    expect(message).not_to be_valid
  end

  it 'rejects a checkout uri on another path' do
    action = card[:actions].first.merge(uri: 'https://support.example.com/checkout?goods_id=13&sku_id=13055&catalog_env=prod')
    message.content_attributes = plan_group([card.merge(actions: [action])])

    expect(message).not_to be_valid
  end

  it 'rejects an unknown catalog environment' do
    action = card[:actions].first.merge(uri: 'https://support.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=staging')
    message.content_attributes = plan_group([card.merge(actions: [action])])

    expect(message).not_to be_valid
  end

  it 'rejects an oversized title' do
    message.content_attributes = plan_group([card.merge(title: 'a' * 161)])

    expect(message).not_to be_valid
  end

  it 'rejects control characters in a fact value' do
    message.content_attributes = plan_group([card.merge(facts: [{ icon: 'wifi', label: 'Data', value: "10\u0000GB" }])])

    expect(message).not_to be_valid
  end

  it 'still rejects unknown keys on a plain card' do
    message.content_attributes = { items: [card] }

    expect(message).not_to be_valid
  end
end

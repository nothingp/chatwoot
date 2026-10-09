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
  let(:checkout_url) { 'https://support.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod' }
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

  it 'accepts an empty country image as the no-image form' do
    message.content_attributes = plan_group([card.merge(country_image: '')])

    expect(message).to be_valid
  end

  it 'rejects a country image carrying a fragment' do
    message.content_attributes = plan_group([card.merge(country_image: 'https://cdn.example.com/jp.svg#flag')])

    expect(message).not_to be_valid
  end

  it 'rejects a country image carrying credentials' do
    message.content_attributes = plan_group([card.merge(country_image: 'https://user:pw@cdn.example.com/jp.svg')])

    expect(message).not_to be_valid
  end

  it 'accepts a country image of exactly 2048 characters' do
    image = "https://cdn.example.com/#{'a' * 2024}"
    message.content_attributes = plan_group([card.merge(country_image: image)])

    expect(message).to be_valid
  end

  it 'rejects a country image past 2048 characters' do
    image = "https://cdn.example.com/#{'a' * 2025}"
    message.content_attributes = plan_group([card.merge(country_image: image)])

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

  # The website embeds the widget in a sandboxed iframe, where a link cannot open the checkout, so
  # its action carries the same url as a postback payload the host page reads and opens.
  context 'with a postback action' do
    let(:payload) { { type: 'checkout', url: checkout_url } }
    let(:postback) { { type: 'postback', text: 'View plan', payload: JSON.generate(payload) } }
    let(:postback_card) { card.merge(actions: [postback]) }
    # The url rides in JSON, so the payload bound is the uri bound minus this wrapper.
    let(:payload_wrapper) { JSON.generate(type: 'checkout', url: '').length }

    # Every example here swaps the action alone, so the card wrapper is written once.
    def plan_grouped(action)
      plan_group([card.merge(actions: [action])])
    end

    it 'accepts a payload carrying the checkout url' do
      message.content_attributes = plan_group([postback_card])

      expect(message).to be_valid
    end

    it 'rejects a payload that is not JSON' do
      message.content_attributes = plan_grouped(postback.merge(payload: 'not json'))

      expect(message).not_to be_valid
    end

    it 'rejects a payload whose type is not checkout' do
      message.content_attributes = plan_grouped(postback.merge(payload: JSON.generate(payload.merge(type: 'order'))))

      expect(message).not_to be_valid
    end

    it 'rejects a payload with an extra key' do
      message.content_attributes = plan_grouped(postback.merge(payload: JSON.generate(payload.merge(label: 'Buy'))))

      expect(message).not_to be_valid
    end

    it 'rejects a payload missing the url' do
      message.content_attributes = plan_grouped(postback.merge(payload: JSON.generate(type: 'checkout')))

      expect(message).not_to be_valid
    end

    # JSON.parse answers an array, a number, a string or null just as happily; none of them is the
    # payload shape, and none of them may raise.
    it 'rejects a payload that is valid JSON but not an object' do
      validities = ['[]', '1', '"x"', 'null'].map do |json|
        message.content_attributes = plan_grouped(postback.merge(payload: json))
        message.valid?
      end

      expect(validities).to eq([false, false, false, false])
    end

    it 'rejects a payload whose url is not a string' do
      message.content_attributes = plan_grouped(postback.merge(payload: JSON.generate(payload.merge(url: 13))))

      expect(message).not_to be_valid
    end

    it 'rejects a payload whose url is not the checkout path' do
      url = checkout_url.sub('/app-actions/checkout', '/checkout')
      message.content_attributes = plan_grouped(postback.merge(payload: JSON.generate(payload.merge(url: url))))

      expect(message).not_to be_valid
    end

    it 'rejects a payload whose url misses a query term' do
      message.content_attributes = plan_grouped(postback.merge(payload: JSON.generate(payload.merge(url: checkout_url.sub('&catalog_env=prod', '')))))

      expect(message).not_to be_valid
    end

    # http stays legal -- checkout_uri? takes both schemes -- so this uses a scheme the app cannot
    # hand on at all.
    it 'rejects a payload whose url is on another scheme' do
      message.content_attributes = plan_grouped(postback.merge(payload: JSON.generate(payload.merge(url: checkout_url.sub('https://', 'ftp://')))))

      expect(message).not_to be_valid
    end

    it 'accepts a payload of exactly 2048 characters' do
      url = checkout_url.sub('support', "support#{'a' * (2048 - payload_wrapper - checkout_url.length)}")
      padded = JSON.generate(payload.merge(url: url))
      message.content_attributes = plan_grouped(postback.merge(payload: padded))

      expect(padded.length).to eq(2048)
      expect(message).to be_valid
    end

    it 'rejects a payload past 2048 characters' do
      url = checkout_url.sub('support', "support#{'a' * (2048 - payload_wrapper - checkout_url.length + 1)}")
      message.content_attributes = plan_grouped(postback.merge(payload: JSON.generate(payload.merge(url: url))))

      expect(message).not_to be_valid
    end

    it 'rejects a postback without text' do
      message.content_attributes = plan_grouped(postback.except(:text))

      expect(message).not_to be_valid
    end

    it 'rejects an empty action text' do
      message.content_attributes = plan_grouped(postback.merge(text: ''))

      expect(message).not_to be_valid
    end

    it 'rejects an action text past 120 characters' do
      message.content_attributes = plan_grouped(postback.merge(text: 'a' * 121))

      expect(message).not_to be_valid
    end

    # A postback carrying the link's own keys is the shape the validator used to accept; it must not.
    it 'rejects a postback carrying the link keys' do
      message.content_attributes = plan_group([card.merge(actions: [card[:actions].first.merge(type: 'postback')])])

      expect(message).not_to be_valid
    end
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

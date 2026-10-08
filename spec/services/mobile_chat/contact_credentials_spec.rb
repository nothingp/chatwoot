require 'rails_helper'

RSpec.describe MobileChat::ContactCredentials do
  let(:contact) { create(:contact, account: create(:account)) }
  let(:identity) { instance_double(MobileChat::IdentityResolver::Identity, token: token) }
  let(:token) { 'member-token' }
  let(:session) { { locale: 'zh_CN', platform: 'ios', catalog_environment: 'prod', currency: 'CNY' } }

  it 'writes the app token onto the contact' do
    described_class.sync(contact, identity, session: {})

    expect(contact.reload.custom_attributes['app_token']).to eq('member-token')
  end

  it 'writes the session values onto the contact' do
    described_class.sync(contact, identity, session: session)

    expect(contact.reload.custom_attributes).to include(
      'locale' => 'zh_CN',
      'platform' => 'ios',
      'catalog_environment' => 'prod',
      'currency' => 'CNY'
    )
  end

  it 'refreshes a rotated app token' do
    contact.update!(custom_attributes: { 'app_token' => 'old-token' })

    described_class.sync(contact, identity, session: {})

    expect(contact.reload.custom_attributes['app_token']).to eq('member-token')
  end

  it 'keeps unrelated custom attributes' do
    contact.update!(custom_attributes: { 'plan' => 'gold', 'app_token' => 'old-token' })

    described_class.sync(contact, identity, session: session)

    expect(contact.reload.custom_attributes).to eq(
      'plan' => 'gold',
      'app_token' => 'member-token',
      'locale' => 'zh_CN',
      'platform' => 'ios',
      'catalog_environment' => 'prod',
      'currency' => 'CNY'
    )
  end

  it 'leaves the contact alone when there is nothing to record' do
    anonymous = instance_double(MobileChat::IdentityResolver::Identity, token: nil)

    expect { described_class.sync(contact, anonymous, session: {}) }.not_to(change { contact.reload.updated_at })
  end

  it 'does not write when every value is already current' do
    described_class.sync(contact, identity, session: session)

    expect { described_class.sync(contact, identity, session: session) }.not_to(change { contact.reload.updated_at })
  end

  it 'drops blank values and bounds long ones' do
    described_class.sync(contact, identity, session: { locale: '', platform: 'x' * 200 })

    expect(contact.reload.custom_attributes).not_to have_key('locale')
    expect(contact.reload.custom_attributes['platform'].length).to eq(described_class::MAX_VALUE_LENGTH)
  end
end

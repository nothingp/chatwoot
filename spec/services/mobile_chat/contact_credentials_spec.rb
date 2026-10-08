require 'rails_helper'

RSpec.describe MobileChat::ContactCredentials do
  let(:contact) { create(:contact, account: create(:account)) }

  it 'writes the app token onto the contact' do
    described_class.sync(contact, 'member-token')

    expect(contact.reload.custom_attributes['app_token']).to eq('member-token')
  end

  it 'refreshes a rotated app token' do
    contact.update!(custom_attributes: { 'app_token' => 'old-token' })

    described_class.sync(contact, 'new-token')

    expect(contact.reload.custom_attributes['app_token']).to eq('new-token')
  end

  it 'keeps unrelated custom attributes' do
    contact.update!(custom_attributes: { 'plan' => 'gold', 'app_token' => 'old-token' })

    described_class.sync(contact, 'new-token')

    expect(contact.reload.custom_attributes).to eq('plan' => 'gold', 'app_token' => 'new-token')
  end

  it 'leaves the contact alone for an anonymous session' do
    expect { described_class.sync(contact, nil) }.not_to(change { contact.reload.updated_at })
  end

  it 'does not write when the token is unchanged' do
    contact.update!(custom_attributes: { 'app_token' => 'same-token' })

    expect { described_class.sync(contact, 'same-token') }.not_to(change { contact.reload.updated_at })
  end
end

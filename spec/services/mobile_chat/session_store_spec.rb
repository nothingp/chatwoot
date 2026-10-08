require 'rails_helper'

RSpec.describe MobileChat::SessionStore do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account)) }

  describe '.create' do
    it 'returns a uuid v4 session id' do
      session_id = described_class.create(contact_inbox: contact_inbox, inbox: inbox)

      expect(session_id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    it 'stores the inbox and contact inbox ids under a 20 minute ttl' do
      session_id = described_class.create(contact_inbox: contact_inbox, inbox: inbox)

      expect(Redis::Alfred.ttl(described_class.key(session_id))).to be_within(5).of(20.minutes.to_i)
    end
  end

  describe '.read' do
    it 'returns the stored ids' do
      session_id = described_class.create(contact_inbox: contact_inbox, inbox: inbox)

      expect(described_class.read(session_id)).to eq(
        'contact_inbox_id' => contact_inbox.id,
        'inbox_id' => inbox.id
      )
    end

    it 'returns nil for an unknown session' do
      expect(described_class.read(SecureRandom.uuid)).to be_nil
    end

    it 'returns nil for a blank session id' do
      expect(described_class.read(nil)).to be_nil
    end
  end

  describe '.expires_at' do
    it 'returns a millisecond timestamp inside the 20 minute window' do
      before_call = Time.current
      expires_at = described_class.expires_at
      after_call = Time.current

      expect(expires_at).to be_a(Integer)
      expect(expires_at).to be > (before_call.to_i * 1000) + 1_000
      expect(expires_at).to be <= (after_call.to_i + (20 * 60)) * 1000
    end
  end
end

require 'rails_helper'

RSpec.describe MobileChat::IdentityResolver do
  let(:installation_id) { '3f2504e0-4f89-41d3-9a0c-0305e82c3301' }
  let(:anonymous_profile_id) { '9c858901-8a57-4791-81fe-4c455b099bc9' }

  describe '#perform without a token' do
    it 'derives the guest identifier from the installation and profile ids' do
      identity = described_class.new(
        token: nil, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.identifier).to eq("guest_#{installation_id}_#{anonymous_profile_id}")
      expect(identity.name).to be_nil
      expect(identity.email).to be_nil
      expect(identity.token).to be_nil
    end

    it 'lower cases the guest identifier so the persisted contract is canonical' do
      identity = described_class.new(
        token: nil, installation_id: installation_id.upcase, anonymous_profile_id: anonymous_profile_id.upcase
      ).perform

      expect(identity.identifier).to eq("guest_#{installation_id}_#{anonymous_profile_id}")
    end

    it 'does not call the business API' do
      expect(MobileChat::NovyroClient).not_to receive(:new)

      described_class.new(
        token: nil, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform
    end
  end

  describe '#perform with a token the business API accepts' do
    let(:token) { 'member-token' }

    before do
      allow(MobileChat::NovyroClient).to receive(:new).with(token: token).and_return(
        instance_double(MobileChat::NovyroClient,
                        user_info: { 'id' => 1001, 'nickname' => 'Zhang San', 'email' => 'user@example.com' })
      )
    end

    it 'derives the member identifier and keeps the token' do
      identity = described_class.new(
        token: token, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.identifier).to eq('member_1001')
      expect(identity.name).to eq('Zhang San')
      expect(identity.email).to eq('user@example.com')
      expect(identity.token).to eq('member-token')
    end

    it 'treats an empty nickname and email as absent' do
      allow(MobileChat::NovyroClient).to receive(:new).with(token: token).and_return(
        instance_double(MobileChat::NovyroClient, user_info: { 'id' => 1001, 'nickname' => '', 'email' => '' })
      )

      identity = described_class.new(
        token: token, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.identifier).to eq('member_1001')
      expect(identity.name).to be_nil
      expect(identity.email).to be_nil
    end
  end

  describe '#perform with a token the business API rejects' do
    let(:token) { 'expired-token' }

    before do
      allow(MobileChat::NovyroClient).to receive(:new).with(token: token).and_return(
        instance_double(MobileChat::NovyroClient, user_info: nil)
      )
    end

    it 'falls back to the guest identity' do
      identity = described_class.new(
        token: token, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.identifier).to eq("guest_#{installation_id}_#{anonymous_profile_id}")
    end

    it 'does not carry the rejected token' do
      identity = described_class.new(
        token: token, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.token).to be_nil
    end
  end

  describe 'Identity#contact_attributes' do
    it 'maps to the builder attribute hash' do
      identity = described_class.new(
        token: nil, installation_id: installation_id, anonymous_profile_id: anonymous_profile_id
      ).perform

      expect(identity.contact_attributes).to eq(
        identifier: "guest_#{installation_id}_#{anonymous_profile_id}",
        name: nil,
        email: nil
      )
    end
  end
end

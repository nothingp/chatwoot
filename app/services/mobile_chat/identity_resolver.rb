class MobileChat::IdentityResolver
  # identifier is persisted into contact.identifier, so this shape is a long-term contract.
  Identity = Data.define(:identifier, :name, :email, :token) do
    def contact_attributes
      { identifier: identifier, name: name, email: email }
    end
  end

  MEMBER_PREFIX = 'member_'
  GUEST_PREFIX = 'guest_'

  def initialize(token:, installation_id:, anonymous_profile_id:)
    @token = token.presence
    @installation_id = installation_id.to_s.downcase
    @anonymous_profile_id = anonymous_profile_id.to_s.downcase
  end

  def perform
    member_identity || guest_identity
  end

  private

  attr_reader :token, :installation_id, :anonymous_profile_id

  def member_identity
    return if token.blank?

    member = MobileChat::NovyroClient.new(token: token).user_info
    return if member.blank?

    Identity.new(
      identifier: "#{MEMBER_PREFIX}#{member['id']}",
      name: member['nickname'].presence,
      email: member['email'].presence,
      token: token
    )
  end

  def guest_identity
    Identity.new(
      identifier: "#{GUEST_PREFIX}#{installation_id}_#{anonymous_profile_id}",
      name: nil,
      email: nil,
      token: nil
    )
  end
end

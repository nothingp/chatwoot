module MobileChat::ContactCredentials
  APP_TOKEN_KEY = 'app_token'

  # ContactInboxWithContactBuilder does not touch an existing contact, and skips creating
  # one entirely when the verified email matches an existing contact. Refresh explicitly so
  # later Captain tools always read the app token of the current login.
  def self.sync(contact, token)
    return if token.blank?
    return if contact.custom_attributes[APP_TOKEN_KEY] == token

    contact.update!(custom_attributes: contact.custom_attributes.merge(APP_TOKEN_KEY => token))
  end
end

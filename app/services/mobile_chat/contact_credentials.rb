module MobileChat::ContactCredentials
  APP_TOKEN_KEY = 'app_token'
  # Client-supplied, so bounded: a hostile value must not be able to bloat the stored hash (it is
  # rendered into every Captain prompt).
  MAX_VALUE_LENGTH = 32
  SESSION_KEYS = %i[locale platform catalog_environment currency].freeze

  # ContactInboxWithContactBuilder does not touch an existing contact, and skips creating one
  # entirely when the verified email matches an existing contact. Refresh explicitly so later
  # Captain tools always read the app token of the current login.
  #
  # The session POST is also the only place a client says how to talk to it: the locale its copy
  # should be in, the platform (a card's buy button works differently on the website and in the
  # app), the catalog environment a checkout link needs, and the currency to price in. Those are
  # per-customer values, so they live on the contact alongside the token.
  def self.sync(contact, identity, session: {})
    attributes = session_attributes(session)
    attributes[APP_TOKEN_KEY] = identity.token if identity.token.present?
    return if attributes.blank? || contact.custom_attributes.slice(*attributes.keys) == attributes

    contact.update!(custom_attributes: contact.custom_attributes.merge(attributes))
  end

  def self.session_attributes(session)
    SESSION_KEYS.filter_map do |key|
      value = session[key].presence
      [key.to_s, value.to_s.truncate(MAX_VALUE_LENGTH)] if value
    end.to_h
  end
end

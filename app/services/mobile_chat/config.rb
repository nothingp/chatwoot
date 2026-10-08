module MobileChat::Config
  # These values back deployment configuration that must exist in production: a blank
  # value is an operator error, so raise instead of silently degrading to anonymous.
  def self.inbox
    ::Inbox.find_by(id: value('MOBILE_CHAT_INBOX_ID')) ||
      raise(CustomExceptions::MobileChat::NotConfigured, 'MOBILE_CHAT_INBOX_ID')
  end

  def self.frontend_url
    ENV.fetch('FRONTEND_URL', nil).presence ||
      raise(CustomExceptions::MobileChat::NotConfigured, 'FRONTEND_URL')
  end

  def self.novyro_user_info_url
    "#{value('NOVYRO_API_BASE_URL')}#{value('NOVYRO_USER_INFO_PATH')}"
  end

  def self.novyro_headers
    {
      'Accept' => 'application/json',
      'x-api-key' => value('NOVYRO_API_KEY'),
      'site-id' => value('NOVYRO_SITE_ID')
    }
  end

  def self.value(name)
    InstallationConfig.find_by(name: name)&.value.presence ||
      raise(CustomExceptions::MobileChat::NotConfigured, name)
  end
end

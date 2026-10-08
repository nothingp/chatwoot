module MobileChat::Config
  # These values back deployment configuration that must exist in production: a blank
  # value is an operator error, so raise instead of silently degrading to anonymous.
  def self.inbox
    ::Inbox.find_by(id: value('MOBILE_CHAT_INBOX_ID')) ||
      raise(CustomExceptions::MobileChat::NotConfigured, 'MOBILE_CHAT_INBOX_ID')
  end

  # A trailing slash is not cosmetic here: the frontend compares this origin against the
  # browser's canonical URL origin with strict string equality, so 'https://host/' would fail
  # the comparison and surface as "customer service unavailable" on a correct deployment.
  def self.frontend_url
    configured = ENV.fetch('FRONTEND_URL', nil).presence ||
                 raise(CustomExceptions::MobileChat::NotConfigured, 'FRONTEND_URL')

    configured.chomp('/')
  end

  # A malformed base yields a URL SafeFetch rejects, which NovyroClient rescues into nil, which
  # silently downgrades every member to an anonymous guest. Raise instead.
  def self.novyro_base_url
    base = value('NOVYRO_API_BASE_URL').chomp('/')

    return base if absolute_http_url?(base)

    raise(CustomExceptions::MobileChat::NotConfigured, 'NOVYRO_API_BASE_URL')
  end

  def self.novyro_url(path)
    "#{novyro_base_url}/#{path.to_s.delete_prefix('/')}"
  end

  def self.novyro_user_info_url
    novyro_url(value('NOVYRO_USER_INFO_PATH'))
  end

  def self.absolute_http_url?(url)
    uri = URI.parse(url)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
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

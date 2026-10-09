class Widget::TokenService < BaseTokenService
  DEFAULT_EXPIRY_DAYS = 180

  # Public so the mobile-chat handoff can live exactly as long as the token it grants.
  def self.expiry_days
    (InstallationConfig.find_by(name: 'WIDGET_TOKEN_EXPIRY')&.value.presence || DEFAULT_EXPIRY_DAYS).to_i
  end

  def generate_token
    JWT.encode(token_payload, secret_key, algorithm)
  end

  private

  def token_payload
    (payload || {}).merge(exp: exp, iat: iat)
  end

  def iat
    Time.zone.now.to_i
  end

  def exp
    iat + expire_in.days.to_i
  end

  def expire_in
    # Value is stored in days, defaulting to 6 months (180 days)
    self.class.expiry_days
  end
end

# frozen_string_literal: true

class CustomExceptions::MobileChat::NotConfigured < CustomExceptions::Base
  def message
    "Mobile chat is not configured: #{@data}"
  end

  def to_hash
    { error: message }
  end

  def http_status
    :internal_server_error
  end
end

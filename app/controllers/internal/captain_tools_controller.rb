# Serves the Captain custom tools that need the customer's own credentials.
#
# A custom tool is a static HTTP template: it cannot read contact attributes, so it cannot put
# the customer's app token into its request. This endpoint closes that gap by resolving the
# conversation locally -- where the contact already is -- and delegating to
# MobileChat::CaptainToolkit.
#
# It lives outside /public/api on purpose: those routes are CORS-open, and a browser must never
# be able to call this. The only protection it needs is the shared secret in X-Internal-Token,
# which the tool sends from its manifest headers.
class Internal::CaptainToolsController < ActionController::Base
  skip_before_action :verify_authenticity_token
  before_action :verify_internal_token

  def create
    conversation = ::Conversation.find_by(
      id: conversation_id,
      account_id: account_id
    )
    # Scoping by account here is what stops one account's tool call from reading another's
    # conversation by guessing an id.
    return render(json: { ok: false, error: 'Conversation not found.' }) if conversation.blank?

    render json: toolkit_for(conversation).call(tool_slug, tool_params)
  end

  private

  def toolkit_for(conversation)
    MobileChat::CaptainToolkit.new(conversation)
  end

  def verify_internal_token
    expected = MobileChat::Config.value('MOBILE_CHAT_INTERNAL_TOOL_TOKEN')
    provided = request.headers['X-Internal-Token'].to_s

    return if provided.present? && ActiveSupport::SecurityUtils.secure_compare(expected, provided)

    head :unauthorized
  end

  def conversation_id
    request.headers['X-Chatwoot-Conversation-Id'].to_i
  end

  def account_id
    request.headers['X-Chatwoot-Account-Id'].to_i
  end

  def tool_slug
    request.headers['X-Chatwoot-Tool-Slug'].to_s
  end

  # The tool posts the model-supplied arguments as a JSON body.
  def tool_params
    request.request_parameters
  end
end

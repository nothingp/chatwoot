# Shared plumbing for the tools that read Novyro data on the customer's behalf.
#
# They all need the same thing -- the conversation, because the customer's app token lives on
# its contact -- and nothing else. find_conversation already scopes by account, so one account's
# tool call can never reach another account's conversation.
class Captain::Tools::MobileChatTool < Captain::Tools::BasePublicTool
  private

  # Returns the toolkit for this call, or nil when the conversation is not resolvable.
  def toolkit(tool_context)
    conversation = find_conversation(tool_context.state)
    return if conversation.blank?

    MobileChat::CaptainToolkit.new(conversation)
  end
end

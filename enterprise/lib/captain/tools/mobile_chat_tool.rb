# Shared plumbing for the tools that read Novyro data on the customer's behalf.
#
# Only the order tools need the conversation, because the customer's app token lives on its
# contact. The product tools read the public catalogue and need no identity at all, so the
# conversation is optional here -- which is also what lets them work in the Playground, where
# there is no conversation in the tool context. find_conversation scopes by account, so one
# account's tool call can never reach another account's conversation.
class Captain::Tools::MobileChatTool < Captain::Tools::BasePublicTool
  private

  def toolkit(tool_context)
    MobileChat::CaptainToolkit.new(find_conversation(tool_context.state))
  end

  # Cards render natively in the widget, but they need a conversation to live in. The Playground
  # has none, so a tool that cannot post still returns its JSON for the model to read out.
  def post_cards(tool_context, cards)
    return false if cards.blank?

    conversation = find_conversation(tool_context.state)
    return false if conversation.blank?

    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content_type: :cards,
      # The widget only renders an agent bubble when the message has content
      # (AgentMessage#shouldDisplayAgentMessage returns message.content), so a content-less
      # cards message is created correctly and then never shown. Titles are data we already
      # have, so they add no language of their own.
      content: cards.map { |card| card[:title] }.join(' · '),
      content_attributes: { items: cards }
    )
    true
  end
end

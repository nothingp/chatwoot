class Captain::Tools::ListOrderTool < Captain::Tools::MobileChatTool
  description 'List the signed-in customer\'s eSIM orders. Call this before answering anything about their orders.'

  def perform(tool_context, **_params)
    tools = toolkit(tool_context)
    return failure_result('Conversation not found', tool_context.state) if tools.blank?

    tools.list_orders.to_json
  end
end

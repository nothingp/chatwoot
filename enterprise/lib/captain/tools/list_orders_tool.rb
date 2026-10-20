class Captain::Tools::ListOrdersTool < Captain::Tools::MobileChatTool
  description 'List the signed-in customer\'s eSIM orders. Call this before answering anything about their orders.'

  def perform(tool_context, **_params)
    toolkit(tool_context).list_orders.to_json
  end
end

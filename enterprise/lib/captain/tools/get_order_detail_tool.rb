class Captain::Tools::GetOrderDetailTool < Captain::Tools::MobileChatTool
  description 'Read one order of the signed-in customer. Use the order_id or order_no returned by the list_orders tool.'
  parameter :order_id, type: 'string', description: 'Order id from the list_orders tool', required: false
  parameter :order_no, type: 'string', description: 'Order number from the list_orders tool', required: false

  def perform(tool_context, **params)
    tools = toolkit(tool_context)
    return failure_result('Conversation not found', tool_context.state) if tools.blank?

    tools.get_order_details(params).to_json
  end
end

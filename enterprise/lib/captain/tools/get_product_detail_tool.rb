class Captain::Tools::GetProductDetailTool < Captain::Tools::MobileChatTool
  description 'Read live catalogue details for one product. Only needed when the recommendation or search result is incomplete or conflicting.'
  parameter :product_id, type: 'string', description: 'Product id from a recommendation or search result', required: true

  def perform(tool_context, **params)
    tools = toolkit(tool_context)
    return failure_result('Conversation not found', tool_context.state) if tools.blank?

    tools.get_product_details(params).to_json
  end
end

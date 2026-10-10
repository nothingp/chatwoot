class Captain::Tools::GetProductDetailsTool < Captain::Tools::MobileChatTool
  description 'Read live catalogue details for one product. Only needed when the recommendation or search result is incomplete or conflicting.'
  parameter :product_id, type: 'string', description: 'Product id from a recommendation or search result', required: true

  def perform(tool_context, **params)
    toolkit(tool_context).get_product_details(params).to_json
  end
end

class Captain::Tools::SearchProductTool < Captain::Tools::MobileChatTool
  description 'Search the eSIM catalogue by keyword: a country, a region, or a product name.'
  parameter :keyword, type: 'string', description: 'What to search for, e.g. Japan or Europe', required: true

  def perform(tool_context, **params)
    tools = toolkit(tool_context)
    return failure_result('Conversation not found', tool_context.state) if tools.blank?

    tools.search_products(params).to_json
  end
end

class Captain::Tools::RecommendPlanTool < Captain::Tools::MobileChatTool
  description 'Recommend eSIM plans for a destination and trip length, with prices. Call this before recommending a plan.'
  parameter :country_code, type: 'string', description: 'ISO 3166-1 alpha-2 destination code, e.g. JP', required: true
  parameter :billing_period, type: 'integer', description: 'Trip length in days, e.g. 7', required: true

  def perform(tool_context, **params)
    toolkit(tool_context).recommend_plans(params).to_json
  end
end

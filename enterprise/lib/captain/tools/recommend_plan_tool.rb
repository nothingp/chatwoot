class Captain::Tools::RecommendPlanTool < Captain::Tools::MobileChatTool
  description 'Recommend eSIM plans for a destination and trip length, with prices. Call this before recommending a plan.'
  parameter :country_code, type: 'string', description: 'ISO 3166-1 alpha-2 destination code, e.g. JP', required: true
  parameter :billing_period, type: 'integer', description: 'Trip length in days, e.g. 7', required: true

  def perform(tool_context, **params)
    tools = toolkit(tool_context)
    result = tools.recommend_plans(params)
    cards = tools.plan_cards(result)

    return result.to_json unless post_cards(tool_context, cards)

    "Posted #{cards.size} plan cards to the customer. Their buttons carry the purchase action, " \
      'so refer to the cards instead of repeating the prices in your reply.'
  end
end

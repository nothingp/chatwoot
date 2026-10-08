# Records the plan the model decided to recommend and posts it as cards. The model only chooses
# which SKUs; prices, data, validity and the checkout link come from the catalogue on this call,
# so a hallucinated number cannot reach a customer's purchase surface.
class Captain::Tools::CreatePurchaseActionTool < Captain::Tools::MobileChatTool
  description 'Post the recommended plan as cards. Call this in the same turn you first mention a ' \
              'concrete plan, using sku ids from this turn\'s recommend_plans result, with the most ' \
              'recommended sku first.'
  parameter :product_id, type: 'string', description: 'Product id from recommend_plans, e.g. 13', required: true
  parameter :sku_ids, type: 'array', description: 'Sku ids from recommend_plans, most recommended first, at most 5', required: true
  parameter :reason, type: 'string', required: true,
                     description: 'One sentence, in the customer\'s language, saying why the first sku fits their trip'
  parameter :label, type: 'string', description: 'Button text for the first card, in the customer\'s language, e.g. Japan 7 days 10GB', required: true

  def perform(tool_context, **params)
    result = toolkit(tool_context).purchase_actions(params)
    return result[:error] if result[:ok] == false
    return result.to_json unless post_cards(tool_context, result[:cards])

    "Posted #{result[:cards].size} plan cards to the customer. Their buttons carry the purchase " \
      'action, so refer to the cards instead of repeating the prices in your reply.'
  end
end

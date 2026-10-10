# 把 5 个新工具挂到对应的 Scenario 上，并让 instruction 里已有的"先查证据"规则真正可执行。
#
# ⚠️ 必须在部署了 b131f99dc9（原生工具类）之后才能跑。
#    Scenario#validate_instruction_tools 会把 instruction 里的 tool:// 引用拿去比
#    assistant.known_tool_ids，而 known_tool_ids 只包含"类能被解析出来"的工具。
#    工具类还没部署时，update! 会直接校验失败（errors: contains invalid tools: ...）。
#
# 用法（服务器上）：
#   sudo docker cp apply_captain_scenarios.rb chatwoot-upstream-rails-1:/tmp/apply_captain_scenarios.rb
#   sudo docker exec chatwoot-upstream-rails-1 bundle exec rails runner /tmp/apply_captain_scenarios.rb
#
# 幂等：已经加过的行会跳过；重复跑不会重复插入。

# scenario id -> 要插进它 "## Tools" 段的行（插在 FAQ Lookup 那行之后）
#
# Product & compatibility 这条引用两个工具：recommend_plans 现在**只回数据**（带 sku_id 的目录），
# 发卡由 create_purchase_action 负责，且必须在同一轮里调用 —— 卡片才是客户看到和购买的东西。
ADDITIONS = {
  5 => <<~TEXT, # Product & compatibility
    - Use [Recommend Plans](tool://recommend_plans) to read the live catalog for the customer's destination and trip length. It returns the sku ids, data sizes and prices the recommendation has to be built from.
    - Use [Create Purchase Action](tool://create_purchase_action) in the same turn you first mention a concrete plan, with the sku ids from that result (most recommended first), a one-sentence reason, and a short button label in the customer's language. The cards carry the prices and the purchase entry point, so do not repeat them in your reply.
    - Only after you have actually called [Create Purchase Action](tool://create_purchase_action) in this turn may you mention the cards. They are posted before your reply is written, so they appear ABOVE your message: then never write "see below" or any wording that puts them under your reply — refer to them as already shown, or do not mention their position at all. If you have not posted cards in this turn, do not mention cards at all.
    - Use [Search Products](tool://search_products) when the customer asks whether a destination or region is covered.
    - Use [Get Product Details](tool://get_product_details) when the recommendation or search result is incomplete or conflicting.
  TEXT
  7 => <<~TEXT # Orders & refunds
    - Use [List Orders](tool://list_orders) to read the signed-in customer's orders instead of asking them for order identifiers.
    - Use [Get Order Details](tool://get_order_details) once you have an order id or number from the order list.
  TEXT
}.freeze

FAQ_ANCHOR = '- Use [FAQ Lookup](tool://faq_lookup)'.freeze

# 下面的新指令取代了这两行的旧写法；不删旧行就会两条并存、互相打架。
#
# ⚠️ 必须**整行精确匹配**，不能用前缀匹配：新行的前缀和旧行一样
#    （都是 `- Use [Create Purchase Action](tool://create_purchase_action)`），
#    用前缀会把刚插进去的新行也删掉，而插入逻辑又认为"它本来就在指令里"从而跳过，
#    结果整行消失（2026-10-08 实际踩到，scenario 5 的工具里少了 create_purchase_action）。
SUPERSEDED_LINES = [
  "- Use [Recommend Plans](tool://recommend_plans) before recommending a plan, so the recommendation comes from the live catalog for the customer's destination and trip length.",
  '- Use [Create Purchase Action](tool://create_purchase_action) in the same turn you first mention a concrete plan, with the sku ids from that result (most recommended first), a one-sentence reason, and a short button label in the customer\'s language. The cards carry the prices and the purchase entry point, so do not repeat them in your reply.'
].freeze

ADDITIONS.each do |scenario_id, block|
  scenario = Captain::Scenario.find(scenario_id)
  additions = block.split("\n").map(&:strip).reject(&:empty?)

  if additions.all? { |line| scenario.instruction.include?(line) }
    puts "scenario #{scenario_id} (#{scenario.title}): 已是最新，跳过"
    next
  end

  lines = scenario.instruction.split("\n")
  lines.reject! { |line| SUPERSEDED_LINES.include?(line.strip) }
  anchor = lines.index { |line| line.start_with?(FAQ_ANCHOR) }
  raise "scenario #{scenario_id}: 找不到 Tools 段的锚点，未改动" if anchor.nil?

  lines.insert(anchor + 1, *additions.reject { |line| scenario.instruction.include?(line) })
  scenario.update!(instruction: lines.join("\n"))

  puts "scenario #{scenario_id} (#{scenario.title}): tools=#{scenario.tools.inspect}"
end

assistant = Captain::Assistant.find(1)
puts "assistant 现在能解析到的工具: #{assistant.available_agent_tools.map { |t| t[:id] }.inspect}"

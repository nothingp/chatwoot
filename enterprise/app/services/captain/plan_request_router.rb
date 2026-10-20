# frozen_string_literal: true

# Deterministic routing for plan/recommendation requests.
#
# The orchestrator prompt asks the model to hand off to the Product &
# compatibility scenario, but that decision is sampled: the same message can
# ask for clarification on one run and hand off on the next. This router makes
# the common "destination + trip length" and "which plans for X" requests
# deterministic: the product scenario agent becomes the runner's starting
# agent, so no model routing decision is involved.
class Captain::PlanRequestRouter
  PLAN_TOOLS = %w[recommend_plans create_purchase_action].freeze

  # "7 days", "5-day", "two weeks", "7天", "一周".
  DAY_OR_WEEK = /
    (?<![\d-])
    (?:
      \d{1,3}\s*(?:day|days|night|nights|天|日|晚)
      | \d{1,3}\s*[- ]\s*(?:day|days)\b
      | (?:a|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:day|days|night|nights|week|weeks)\b
      | (?:一|两|二|三|四|五|六|七|八|九|十)\s*个?\s*(?:天|日|周|週)
      | \d{1,3}\s*(?:周|週)
    )
  /ix

  # A duration in the past is order history, not a trip.
  PAST_DURATION = /\b(?:ago|before|since|last|past)\b|前|之前|以前|已经/i

  # Existing-order and installation traffic belongs to the other scenarios.
  EXCLUDED_TERMS = /
    \b(?:order|orders|refund|refunds|install|installs|installation|
         activate|activation|qr|iccid|payment|paid|receipt|warranty)\b
    | 订单 | 退款 | 安装 | 激活 | 二维码 | 支付 | 发票
  /ix

  PLAN_INTENT = /
    \b(?:plan|plans|package|packages|price|prices|pricing|recommend|
         recommends|recommendation|available|availability|options|offer|
         offers|buy|purchase|esim|e-sim)\b
    | 套餐 | 价格 | 推荐 | 方案 | 选择 | 购买 | 多少钱 | 有哪些
  /ix

  STOPWORDS = %w[
    i i'm im me my we us you your he she it they them
    hello hi hey please thanks thank the a an this that these those
    what which when where why who how is are was were be been
    can could would should do does did have has had need want help
    today tomorrow tonight week weekend month year
    sim esim e-sim
  ].freeze

  class << self
    def plan_request?(message)
      text = message.to_s.strip
      return false if text.blank?
      return false if text.match?(EXCLUDED_TERMS)

      duration = text.match?(DAY_OR_WEEK)
      return false if duration && text.match?(PAST_DURATION)
      return false unless destination?(text)
      return true if duration

      text.match?(PLAN_INTENT)
    end

    # The scenario that owns both plan tools. Identifying it by tools rather
    # than by title or id keeps this stable if the scenario is renamed.
    def scenario_for(assistant, message)
      return nil unless plan_request?(message)
      return nil unless assistant.respond_to?(:scenarios)

      assistant.scenarios.enabled.find do |scenario|
        tools = Array(scenario.tools).map(&:to_s)
        (tools & PLAN_TOOLS).size == PLAN_TOOLS.size
      end
    end

    private

    def destination?(text)
      return true if text.match?(/[\p{Han}\p{Hangul}]{2,}/)

      text.scan(/[A-Z][A-Za-z]{2,}/).any? do |word|
        !STOPWORDS.include?(word.downcase)
      end
    end
  end
end

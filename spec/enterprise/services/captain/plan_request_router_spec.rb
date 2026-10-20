# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PlanRequestRouter do
  describe '.plan_request?' do
    {
      'Japan 7 days' => true,
      'Japan for 7 days' => true,
      '5 days in France' => true,
      'Japan for a week' => true,
      '日本 7天' => true,
      '法国 5 天' => true,
      'Which plans do you have for France?' => true,
      'I want to buy a France eSIM' => true,
      '7 days' => false,
      'Hello 5 days' => false,
      'What is an eSIM?' => false,
      'How do I install my eSIM?' => false,
      'My order from 5 days ago' => false,
      'I bought a France plan 5 days ago' => false,
      'What is the weather in France?' => false
    }.each do |message, expected|
      it "returns #{expected} for #{message.inspect}" do
        expect(described_class.plan_request?(message)).to eq(expected)
      end
    end
  end

  describe '.self_contained?' do
    it 'is true when the message carries a destination and a duration' do
      expect(described_class.self_contained?('Japan 7 days')).to be(true)
      expect(described_class.self_contained?('法国 5 天')).to be(true)
    end

    it 'is false without a duration or for a past duration' do
      expect(described_class.self_contained?('France')).to be(false)
      expect(described_class.self_contained?('My order from 5 days ago')).to be(false)
    end
  end

  describe '.scenario_for' do
    let(:product_scenario) do
      instance_double(Captain::Scenario, tools: %w[recommend_plans create_purchase_action])
    end
    let(:other_scenario) { instance_double(Captain::Scenario, tools: %w[faq_lookup]) }
    let(:scenarios) { instance_double(Captain::Scenario, enabled: [other_scenario, product_scenario]) }
    let(:assistant) { instance_double(Captain::Assistant, scenarios: scenarios) }

    it 'returns the scenario that owns both plan tools' do
      expect(described_class.scenario_for(assistant, 'Japan 7 days')).to eq(product_scenario)
    end

    it 'returns nil when the message is not a plan request' do
      expect(described_class.scenario_for(assistant, 'What is an eSIM?')).to be_nil
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Models do
  describe '.providers' do
    it 'loads provider metadata from the config' do
      expect(described_class.providers).to include(
        'openai' => include('display_name' => 'OpenAI')
      )
    end
  end

  describe '.features' do
    it 'keeps every feature default in the allowed model list' do
      described_class.features.each do |feature_key, config|
        expect(config['models']).to include(config['default']), "#{feature_key} default model must be allowed"
      end
    end

    it 'references existing models from every feature' do
      described_class.features.each do |feature_key, config|
        missing_models = config['models'].reject { |model_name| described_class.models.key?(model_name) }

        expect(missing_models).to be_empty, "#{feature_key} references missing models: #{missing_models.join(', ')}"
      end
    end

    it 'routes each FAQ operation independently' do
      expect(described_class.default_model_for('document_faq_generation')).to eq('qwen3.8-flash')
      expect(described_class.default_model_for('conversation_faq_generation')).to eq('qwen3.8-flash')
      expect(described_class.default_model_for('conversation_faq_matching')).to eq('qwen3.8-flash')
    end

    it 'offers only supported OpenAI models for conversation completion' do
      expect(described_class.models_for('conversation_completion')).to eq(
        %w[gpt-4.1-mini gpt-5-mini gpt-4.1 gpt-5.1 gpt-5.2 qwen3.8-flash]
      )
    end
  end

  describe '.models' do
    it 'references existing providers from every model' do
      missing_providers = described_class.models.filter_map do |model_name, config|
        provider = config['provider']
        next if described_class.providers.key?(provider)

        "#{model_name}: #{provider}"
      end

      expect(missing_providers).to be_empty
    end
  end

  describe '.feature_config' do
    it 'returns model metadata for a feature' do
      config = described_class.feature_config('editor')

      expect(config[:default]).to eq('qwen3.8-flash')
      expect(config[:models].first).to include(
        id: 'gpt-4.1-mini',
        display_name: 'GPT-4.1 Mini',
        provider: 'openai',
        credit_multiplier: 1
      )
    end
  end

  describe '.model_params' do
    it 'returns an empty hash for a model without params' do
      expect(described_class.model_params('gpt-4.1')).to eq({})
    end

    it 'returns an empty hash for an unknown model' do
      expect(described_class.model_params('no-such-model')).to eq({})
    end

    it 'returns the configured params with symbol keys' do
      expect(described_class.model_params('qwen3.8-flash')).to eq(enable_thinking: false)
    end

    it 'returns embedding params with symbol keys' do
      expect(described_class.model_params('qwen3.7-text-embedding')).to eq(dimensions: 1536)
    end
  end
end

require 'rails_helper'

RSpec.describe Llm::BaseAiService do
  subject(:service) { described_class.new }

  let(:account) { create(:account) }

  before do
    InstallationConfig.where(name: %w[CAPTAIN_OPEN_AI_API_KEY CAPTAIN_OPEN_AI_MODEL]).destroy_all
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
  end

  describe '#initialize' do
    it 'uses the installation model when no feature is provided' do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_MODEL', value: 'gpt-4.1-nano')

      expect(described_class.new.model).to eq('gpt-4.1-nano')
    end

    it 'uses the account override when feature context is provided' do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_MODEL', value: 'gpt-4.1-nano')
      account.update!(captain_models: { 'assistant' => 'gpt-5.2' })

      expect(described_class.new(feature: 'assistant', account: account).model).to eq('gpt-5.2')
    end

    it 'uses the installation model when feature context has no account override' do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_MODEL', value: 'gpt-4.1-nano')

      expect(described_class.new(feature: 'assistant', account: account).model).to eq('gpt-4.1-nano')
    end

    it 'uses the assistant feature default when Captain V2 is enabled' do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_MODEL', value: 'gpt-4.1-nano')
      account.enable_features!('captain_integration')

      expect(described_class.new(feature: 'assistant', account: account).model).to eq('qwen3.8-flash')
      expect(account.reload.captain_models).to be_nil
    end

    it 'uses the feature default when feature context has no account override or installation model' do
      expect(described_class.new(feature: 'assistant', account: account).model).to eq(Llm::Models.default_model_for('assistant'))
    end
  end

  describe '#sanitize_json_response' do
    it 'strips ```json fences' do
      input = "```json\n{\"key\": \"value\"}\n```"
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'strips bare ``` fences' do
      input = "```\n{\"key\": \"value\"}\n```"
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'passes through plain JSON unchanged' do
      input = '{"key": "value"}'
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'returns nil for nil input' do
      expect(service.send(:sanitize_json_response, nil)).to be_nil
    end

    it 'strips surrounding whitespace' do
      input = "  \n{\"key\": \"value\"}\n  "
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end
  end

  describe '#chat' do
    %w[gpt-5.1 gpt-5.2].each do |model|
      it "omits temperature for #{model} when the model registry marks it unsupported" do
        llm_chat = instance_double(RubyLLM::Chat)
        allow(RubyLLM).to receive(:chat).with(model: model).and_return(llm_chat)

        expect(llm_chat).not_to receive(:with_temperature)
        expect(service.chat(model: model)).to eq(llm_chat)
      end
    end

    it 'sets temperature when the model registry marks it supported' do
      llm_chat = instance_double(RubyLLM::Chat)
      configured_chat = instance_double(RubyLLM::Chat)
      allow(RubyLLM).to receive(:chat).with(model: 'gpt-4.1-mini').and_return(llm_chat)
      allow(llm_chat).to receive(:with_temperature).with(0.7).and_return(configured_chat)

      expect(service.chat(model: 'gpt-4.1-mini', temperature: 0.7)).to eq(configured_chat)
    end

    it 'passes the model params to the chat when the model declares them' do
      llm_chat = instance_double(RubyLLM::Chat)
      configured_chat = instance_double(RubyLLM::Chat)
      allow(RubyLLM).to receive(:chat).with(model: 'qwen3.8-flash').and_return(llm_chat)
      allow(llm_chat).to receive(:with_provider_options).and_return(llm_chat)
      allow(llm_chat).to receive(:with_temperature).with(1.0).and_return(configured_chat)

      service.chat(model: 'qwen3.8-flash')

      expect(llm_chat).to have_received(:with_provider_options).with(enable_thinking: false)
    end

    it 'merges the model params with the provider options the caller passes' do
      llm_chat = instance_double(RubyLLM::Chat)
      allow(RubyLLM).to receive(:chat).with(model: 'qwen3.8-flash').and_return(llm_chat)
      allow(llm_chat).to receive(:with_temperature).and_return(llm_chat)
      allow(llm_chat).to receive(:with_provider_options).and_return(llm_chat)

      service.chat(model: 'qwen3.8-flash', provider_options: { response_format: { type: 'json_object' } })

      expect(llm_chat).to have_received(:with_provider_options)
        .with(enable_thinking: false, response_format: { type: 'json_object' })
    end

    it 'does not set provider options when the model declares none' do
      llm_chat = instance_double(RubyLLM::Chat)
      allow(RubyLLM).to receive(:chat).with(model: 'gpt-5.2').and_return(llm_chat)
      allow(llm_chat).to receive(:with_provider_options)

      service.chat(model: 'gpt-5.2')

      expect(llm_chat).not_to have_received(:with_provider_options)
    end
  end
end

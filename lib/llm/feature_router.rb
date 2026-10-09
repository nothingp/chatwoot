module Llm::FeatureRouter
  class UnknownFeatureError < StandardError; end

  CAPTAIN_V2_ASSISTANT_MODEL = 'gpt-5.2'.freeze
  # pdf_faq_generation needs a model that honours DashScope's fileid:// references (qwen-long) and
  # audio_transcription is disabled, so neither may follow the installation-level chat model.
  # See the design doc §5.1: docs/superpowers/specs/2026-10-09-captain-llm-provider-migration-design.md
  PINNED_MODEL_FEATURES = %w[pdf_faq_generation audio_transcription].freeze

  class << self
    def resolve(feature:, account: nil)
      feature_key = feature.to_s
      raise UnknownFeatureError, "Unknown LLM feature: #{feature_key}" unless Llm::Models.feature?(feature_key)

      model, source = model_and_source(account, feature_key)

      {
        feature: feature_key,
        provider: provider_for(model, source),
        model: model,
        source: source
      }
    end

    private

    def model_and_source(account, feature_key)
      account_model = account_model_override(account, feature_key)
      return [account_model, :account_override] if account_model.present?

      installation_model = installation_model_override(feature_key)
      return [installation_model, :installation_override] if installation_model.present?

      [captain_assistant_model(account, feature_key) || Llm::Models.default_model_for(feature_key), :default]
    end

    def account_model_override(account, feature_key)
      model = account&.captain_models&.[](feature_key).presence
      return unless model
      return model if Llm::Models.valid_model_for?(feature_key, model)
    end

    def installation_model_override(feature_key)
      return if PINNED_MODEL_FEATURES.include?(feature_key)
      return unless ChatwootApp.self_hosted_paid?

      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence
    end

    def provider_for(model, source)
      Llm::Models.provider_for(model) || ('openai' if source == :installation_override)
    end

    def captain_assistant_model(account, feature_key)
      return unless feature_key == 'assistant'
      return unless account&.feature_enabled?('captain_integration')

      CAPTAIN_V2_ASSISTANT_MODEL
    end
  end
end

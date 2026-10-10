module Concerns::Agentable
  extend ActiveSupport::Concern

  DEFAULT_TEMPERATURE = 0.5

  # No response_schema here on purpose: the answer is delivered through
  # Captain::Tools::EmitAnswerTool instead. A schema puts `response_format` on every request,
  # and a gateway that accepts one stops emitting tool calls while it is set -- DashScope does
  # that silently, which would leave the agent unable to call any tool, handoffs included.
  def agent(runtime_configuration: nil, runtime_agent_name: nil)
    model = agent_model
    Agents::Agent.new(
      name: runtime_agent_name || agent_name,
      instructions: ->(context) { agent_instructions(context, runtime_configuration: runtime_configuration) },
      tools: agent_tools + [Captain::Tools::EmitAnswerTool.new],
      model: model,
      temperature: Llm::Models.temperature_for(model, temperature.presence&.to_f || DEFAULT_TEMPERATURE)
    )
  end

  def agent_instructions(context = nil, prompt_template: template_name, runtime_configuration: nil)
    enhanced_context = runtime_prompt_context(prompt_context, runtime_configuration)

    if context
      state = context.context[:state] || {}
      config = state[:assistant_config] || {}
      enhanced_context = enhanced_context.merge(
        current_time: format_current_time(state[:timezone]),
        conversation: state[:conversation] || {},
        contact: config['feature_contact_attributes'].present? ? state[:contact] : nil,
        campaign: state[:campaign] || {},
        message_length_limit: state[:message_length_limit],
        language: reply_language(state, enhanced_context[:language])
      )
    end

    Captain::PromptRenderer.render(prompt_template, enhanced_context.with_indifferent_access)
  end

  def agent_model
    route = Llm::FeatureRouter.resolve(feature: 'assistant', account: account)
    return route[:model] if route[:source] == :account_override || account&.feature_enabled?('captain_integration')

    installation_model.presence || route[:model]
  end

  private

  def runtime_prompt_context(context, runtime_configuration)
    return context unless runtime_configuration

    runtime_configuration.prompt_context_for(self, context)
  end

  # The client declares the language its copy should be in when it opens the session
  # (MobileChat::ContactCredentials records it as `locale` on the contact), so the reply follows
  # the customer rather than the account. Without it, prompt_context's account-level language
  # stands as the fallback.
  def reply_language(state, fallback)
    locale = state.dig(:contact, :custom_attributes, 'locale').presence
    return fallback if locale.blank?

    ISO_639.find(locale.split('_').first)&.english_name&.downcase || locale
  end

  def agent_name
    raise NotImplementedError, "#{self.class} must implement agent_name"
  end

  def template_name
    self.class.name.demodulize.underscore
  end

  def agent_tools
    []  # Default implementation, override if needed
  end

  def installation_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
  end

  def format_current_time(timezone)
    tz = ActiveSupport::TimeZone[timezone] if timezone.present?
    time = tz ? Time.current.in_time_zone(tz) : Time.current
    time.strftime('%A, %B %d, %Y %I:%M %p %Z')
  end

  def prompt_context
    raise NotImplementedError, "#{self.class} must implement prompt_context"
  end
end

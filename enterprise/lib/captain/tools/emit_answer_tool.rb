require 'agents'

# The reply leaves the agent as a tool call rather than through a response schema.
#
# Model gateways that accept a `response_format` stop emitting tool calls while one is set --
# DashScope does it silently (finish_reason flips from tool_calls to stop), which would disable
# every other tool the agent holds. Delivering the answer as a tool keeps the schema's shape
# exactly as `Captain::ResponseSchema` defines it, so the response pipeline reads the same fields.
class Captain::Tools::EmitAnswerTool < Agents::Tool
  # Where the answer is parked on the run's shared state, for the runner to read back.
  STATE_KEY = :captain_emit_answer

  description 'Deliver the final answer to the customer. Call this as the last step of every reply, ' \
              'with the complete customer-visible text. This call is what the customer receives -- ' \
              'text written outside it is never delivered.'

  parameters Captain::ResponseSchema

  def perform(tool_context, **params)
    tool_context.state[STATE_KEY] = params
    'Answer recorded.'
  end
end

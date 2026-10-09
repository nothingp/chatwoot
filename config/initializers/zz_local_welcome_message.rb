# frozen_string_literal: true

# 访客第一次打开组件时，自动建立一个会话并发一条欢迎消息（带可点选项）。
#
# ## 为什么必须由服务端替客户"开个头"
#
# 上游只在客户发出第一条消息时才建会话（Api::V1::Widget::BaseController#create_conversation），
# 而组件 API 也不支持建空会话 —— Api::V1::Widget::ConversationsController#create 里
# 会话和第一条消息在同一个事务里建，message_params 必须带 content。
# 所以"打开即见欢迎语"只能由服务端先建会话、再把欢迎消息塞进去。
#
# ## 为什么挂在 ContactInbox 上
#
# ContactInbox 正好是"这个浏览器第一次见组件"的那一刻：官方 SDK 会把 cw_conversation
# 存成 365 天的 cookie，之后每次加载都带着它回来、复用同一个 ContactInbox
# （app/helpers/widget_helper.rb 的 build_contact_inbox_with_token 只在没有 token 时新建）。
# 所以这个钩子一个访客只会触发一次 —— 欢迎语天然只有一条，不需要记"发过没有"。
#
# 换浏览器 / 清 cookie 会被当成新访客，那本来也就是新会话，重发一条欢迎语是对的。
# 上一轮会话被标记解决后客户再发起，同样走新会话、新欢迎语。
#
# ## 为什么消息类型是 input_select
#
# 这是组件里唯一能渲染成可点选项的消息类型（widget/components/AgentMessageBubble.vue
# 的 isOptions 判的就是 content_type === 'input_select'）。
# 注意：点选项本身不产生 incoming 消息，所以 AgentMessageBubble#onOptionSelect 里
# 额外补了一次 sendMessage，否则 Captain 不会被触发。
module LocalWelcomeMessage
  CONTENT = <<~TEXT.strip
    Hello, adventurer! 🌍✨ At Novyro, we’re here to make your travels seamless and stress-free.

    To assist you as quickly as possible, please select the option that best matches your needs:
  TEXT

  ITEMS = [
    {
      title: '🛒 I want to buy an eSIM → Planning a trip and looking for a data plan at your destination.',
      value: 'buy-esim'
    },
    {
      title: '🛠️ I need help with my eSIM → Already purchased and experiencing issues? (connection problems, QR code, installation).',
      value: 'help-esim'
    }
  ].freeze

  def start_conversation_with_welcome_message
    return unless inbox.channel_type == 'Channel::WebWidget'

    # contact_inboxes 没有 account_id 列，账号要从 inbox 上取。
    account = inbox.account
    # 这个联系人在该渠道里已经有会话了就不再开新的 —— 一次联系人一份欢迎语。
    return if Conversation.exists?(account_id: account.id, inbox_id: inbox_id, contact_id: contact_id)

    conversation = Conversation.create!(
      account_id: account.id,
      inbox_id: inbox_id,
      contact_id: contact_id,
      contact_inbox_id: id
    )
    conversation.messages.create!(
      account_id: account.id,
      inbox_id: inbox_id,
      message_type: :outgoing,
      content_type: :input_select,
      content: CONTENT,
      content_attributes: { items: ITEMS }
    )
  end
end

# 必须包在 to_prepare 里：initializer 阶段 Zeitwerk 还没加载 ContactInbox，
# 直接引用会 NameError。to_prepare 在 initializer 之后、且支持 reload。
Rails.application.config.to_prepare do
  ContactInbox.include(LocalWelcomeMessage)
  ContactInbox.after_create_commit :start_conversation_with_welcome_message
end

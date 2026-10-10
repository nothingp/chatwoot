<script>
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import ChatCard from 'shared/components/ChatCard.vue';
import PlanCards from 'shared/components/PlanCards.vue';
import configMixin from '../mixins/configMixin';
import { isEmptyObject } from 'widget/helpers/utils';
import {
  ON_CAMPAIGN_MESSAGE_CLICK,
  ON_UNREAD_MESSAGE_CLICK,
} from '../constants/widgetBusEvents';
import { emitter } from 'shared/helpers/mitt';

export default {
  name: 'UnreadMessage',
  components: { Avatar, ChatCard, PlanCards },
  mixins: [configMixin],
  props: {
    message: {
      type: String,
      default: '',
    },
    contentType: {
      type: String,
      default: '',
    },
    messageContentAttributes: {
      type: Object,
      default: () => ({}),
    },
    showSender: {
      type: Boolean,
      default: false,
    },
    sender: {
      type: Object,
      default: () => {},
    },
    campaignId: {
      type: Number,
      default: null,
    },
  },
  setup() {
    const { formatMessage, getPlainText, truncateMessage, highlightContent } =
      useMessageFormatter();
    return {
      formatMessage,
      getPlainText,
      truncateMessage,
      highlightContent,
    };
  },
  computed: {
    // A cards message must render as cards here too, exactly as AgentMessageBubble decides it in the
    // conversation view: a card whose content_type went missing is still ours when the variant says so.
    isCards() {
      return this.contentType === 'cards' || this.isNovyroPlanGroup;
    },
    isNovyroPlanGroup() {
      return this.messageContentAttributes?.variant === 'novyro_plan_group';
    },
    companyName() {
      return `${this.$t('UNREAD_VIEW.COMPANY_FROM')} ${
        this.channelConfig.websiteName
      }`;
    },
    avatarUrl() {
      // eslint-disable-next-line
      const displayImage = this.useInboxAvatarForBot
        ? this.inboxAvatarUrl
        : '/assets/images/chatwoot_bot.png';
      if (this.isSenderExist(this.sender)) {
        const { avatar_url: avatarUrl } = this.sender;
        return avatarUrl;
      }
      return displayImage;
    },
    agentName() {
      if (this.isSenderExist(this.sender)) {
        const { available_name: availableName, name } = this.sender;
        return availableName || name || '';
      }
      if (this.useInboxAvatarForBot) {
        return this.channelConfig.websiteName;
      }
      return this.$t('UNREAD_VIEW.BOT');
    },
    availabilityStatus() {
      if (this.isSenderExist(this.sender)) {
        const { availability_status: availabilityStatus } = this.sender;
        return availabilityStatus;
      }
      return null;
    },
  },
  methods: {
    isSenderExist(sender) {
      return sender && !isEmptyObject(sender);
    },
    onClickMessage() {
      if (this.campaignId) {
        emitter.emit(ON_CAMPAIGN_MESSAGE_CLICK, this.campaignId);
      } else {
        emitter.emit(ON_UNREAD_MESSAGE_CLICK);
      }
    },
  },
};
</script>

<template>
  <div class="chat-bubble-wrap">
    <!-- A card carries its own interactive elements (a call to action, the alternative rows), so it
         cannot live inside the bubble button that opens the conversation. -->
    <div v-if="isCards">
      <div v-if="showSender" class="row--agent-block">
        <Avatar
          :src="avatarUrl"
          :size="20"
          :name="agentName"
          :status="availabilityStatus"
          rounded-full
        />
        <span class="agent--name">{{ agentName }}</span>
        <span class="company--name">{{ companyName }}</span>
      </div>
      <PlanCards
        v-if="isNovyroPlanGroup"
        :items="messageContentAttributes.items"
      />
      <template v-else>
        <ChatCard
          v-for="item in messageContentAttributes.items"
          :key="item.title"
          :media-url="item.media_url"
          :title="item.title"
          :description="item.description"
          :actions="item.actions"
        />
      </template>
    </div>
    <button v-else class="chat-bubble agent bg-white" @click="onClickMessage">
      <div v-if="showSender" class="row--agent-block">
        <Avatar
          :src="avatarUrl"
          :size="20"
          :name="agentName"
          :status="availabilityStatus"
          rounded-full
        />
        <span class="agent--name">{{ agentName }}</span>
        <span class="company--name">{{ companyName }}</span>
      </div>
      <div
        v-dompurify-html="formatMessage(message, false)"
        class="message-content"
      />
    </button>
  </div>
</template>

<style lang="scss" scoped>
.chat-bubble {
  @apply max-w-[85%] cursor-pointer p-4;
}

.row--agent-block {
  @apply items-center flex text-left pb-2 text-xs;

  .agent--name {
    @apply font-medium ml-1;
  }

  .company--name {
    @apply text-n-slate-11 dark:text-n-slate-10 ml-1;
  }
}
</style>

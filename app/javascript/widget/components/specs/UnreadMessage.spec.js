import { mount } from '@vue/test-utils';
import UnreadMessage from '../UnreadMessage.vue';
import ChatCard from 'shared/components/ChatCard.vue';
import PlanCards from 'shared/components/PlanCards.vue';

const channelConfig = {
  avatarUrl: '',
  enabledFeatures: [],
  websiteName: 'Example',
};

// A plan group message flattened to its title, the way the server builds the content, must still
// render as the card in the unread list -- the text content is what the list used to show.
const plan = {
  title: '日本',
  description: '7天日本专属行程，10GB总量。',
  media_url: '',
  badge: '最佳匹配',
  facts: [{ icon: 'wifi', label: '流量', value: '10 GB' }],
  actions: [{ type: 'link', text: '查看方案', uri: 'https://example.com/jp' }],
};

const card = {
  title: '日本',
  description: '7天日本专属行程，10GB总量。',
  media_url: 'https://cdn.example.com/jp.svg',
  actions: [{ type: 'link', text: '查看方案', uri: 'https://example.com/jp' }],
};

const mountUnread = (props = {}) =>
  mount(UnreadMessage, {
    props: { message: '日本 · 日本', ...props },
    global: {
      stubs: { Avatar: true, ChatCard: true },
      // Registered by the widget's own entry point, which a component spec does not load.
      directives: {
        dompurifyHtml: (element, binding) => {
          element.textContent = binding.value;
        },
      },
    },
  });

describe('UnreadMessage', () => {
  beforeEach(() => {
    window.chatwootWebChannel = channelConfig;
  });

  afterEach(() => {
    delete window.chatwootWebChannel;
  });

  it('renders the plan cards for a novyro plan group message instead of the flattened text', () => {
    const wrapper = mountUnread({
      contentType: 'cards',
      messageContentAttributes: { variant: 'novyro_plan_group', items: [plan] },
    });

    expect(wrapper.findComponent(PlanCards).props('items')).toEqual([plan]);
    expect(wrapper.find('.message-content').exists()).toBe(false);
  });

  it('renders the plan cards when content_type is missing but the variant is ours', () => {
    const wrapper = mountUnread({
      contentType: '',
      messageContentAttributes: { variant: 'novyro_plan_group', items: [plan] },
    });

    expect(wrapper.findComponent(PlanCards).props('items')).toEqual([plan]);
  });

  it('keeps rendering the plain card list for every other cards message', () => {
    const wrapper = mountUnread({
      contentType: 'cards',
      messageContentAttributes: { items: [card, card] },
    });

    expect(wrapper.findAllComponents(ChatCard)).toHaveLength(2);
    expect(wrapper.findComponent(PlanCards).exists()).toBe(false);
  });

  it('keeps rendering a plain message as text', () => {
    const wrapper = mountUnread({ message: 'Hello' });

    expect(wrapper.find('.message-content').exists()).toBe(true);
    expect(wrapper.findComponent(PlanCards).exists()).toBe(false);
    expect(wrapper.findComponent(ChatCard).exists()).toBe(false);
  });
});

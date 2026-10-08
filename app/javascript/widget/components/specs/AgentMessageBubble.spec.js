import { mount } from '@vue/test-utils';
import AgentMessageBubble from '../AgentMessageBubble.vue';
import ChatCard from 'shared/components/ChatCard.vue';
import PlanCards from 'shared/components/PlanCards.vue';

// The plan group is the one cards variant the widget renders itself; every other cards message has
// to keep going through the plain card list.
const plan = {
  title: '日本',
  description: '7天日本专属行程，10GB总量。',
  media_url: '',
  badge: '最佳匹配',
  facts: [{ icon: 'wifi', label: '流量', value: '10 GB' }],
  actions: [
    {
      type: 'link',
      text: '查看方案',
      uri: 'https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod',
    },
  ],
  country_image:
    'https://admin.esimgo.site/upload/attachment/image/10000/202601/01/JP.svg',
};

const card = {
  title: '日本',
  description: '7天日本专属行程，10GB总量。',
  media_url: 'https://cdn.example.com/jp.svg',
  actions: [{ type: 'link', text: '查看方案', uri: 'https://example.com/jp' }],
};

const mountBubble = messageContentAttributes =>
  mount(AgentMessageBubble, {
    props: { contentType: 'cards', messageContentAttributes },
    global: {
      stubs: { ChatCard: true },
      // Registered by the widget's own entry point, which a component spec does not load.
      directives: { dompurifyHtml: () => {} },
    },
  });

describe('AgentMessageBubble', () => {
  it('renders the plan cards for a novyro plan group message', () => {
    const wrapper = mountBubble({
      variant: 'novyro_plan_group',
      items: [plan],
    });

    expect(wrapper.findComponent(PlanCards).props('items')).toEqual([plan]);
    expect(wrapper.findAllComponents(ChatCard)).toHaveLength(0);
  });

  it('keeps rendering the plain card list for every other cards message', () => {
    const wrapper = mountBubble({ items: [card, card] });

    expect(wrapper.findAllComponents(ChatCard)).toHaveLength(2);
    expect(wrapper.findComponent(PlanCards).exists()).toBe(false);
  });
});

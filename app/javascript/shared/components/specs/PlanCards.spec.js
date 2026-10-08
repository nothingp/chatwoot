import { mount } from '@vue/test-utils';
import PlanCards from '../PlanCards.vue';

// The widget's i18n has no messages in the test setup, so `t` returns the key it was asked for.
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

// What the server sends for a novyro_plan_group message, taken from the contract the app parses.
const card = {
  title: '日本',
  description: '7天日本专属行程，10GB总量。',
  media_url: '',
  badge: '最佳匹配',
  facts: [
    { icon: 'wifi', label: '流量', value: '10 GB' },
    { icon: 'calendar', label: '有效期', value: '7天' },
    { icon: 'wallet', label: '价格', value: 'USD 16.99' },
  ],
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

const alternative = {
  ...card,
  badge: '备选方案',
  facts: [
    { icon: 'wifi', label: '流量', value: '无限流量' },
    { icon: 'calendar', label: '有效期', value: '7天' },
    { icon: 'wallet', label: '价格', value: 'USD 35.99' },
  ],
  actions: [
    {
      ...card.actions[0],
      uri: 'https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13056&catalog_env=prod',
    },
  ],
};

const secondAlternative = {
  ...alternative,
  facts: [
    { icon: 'wifi', label: '流量', value: '3 GB' },
    { icon: 'calendar', label: '有效期', value: '7天' },
  ],
  actions: [
    {
      ...alternative.actions[0],
      uri: 'https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13057&catalog_env=prod',
    },
  ],
};

const cardWithoutFlag = {
  title: card.title,
  description: card.description,
  media_url: card.media_url,
  badge: card.badge,
  facts: card.facts,
  actions: card.actions,
};

const mountCards = items => mount(PlanCards, { props: { items } });

describe('PlanCards', () => {
  test('renders the primary card with its flag, badge, stats and call to action', () => {
    const wrapper = mountCards([card]);
    const primary = wrapper.find('[data-test-id="plan-card-primary"]');

    expect(primary.find('img').attributes('src')).toBe(card.country_image);
    expect(primary.text()).toContain('日本');
    expect(primary.find('[data-test-id="plan-card-badge"]').text()).toBe(
      '最佳匹配'
    );

    const stats = primary.findAll('[data-test-id="plan-card-stat"]');
    expect(stats).toHaveLength(2);
    expect(stats[0].text()).toContain('流量');
    expect(stats[0].text()).toContain('10 GB');
    expect(stats[1].text()).toContain('7天');

    const cta = primary.find('[data-test-id="plan-card-cta"]');
    expect(cta.text()).toBe('查看方案');
    expect(cta.attributes('href')).toBe(card.actions[0].uri);
    expect(cta.attributes('target')).toBe('_blank');
  });

  test('renders the alternatives under the heading, each linking to its own plan', () => {
    const wrapper = mountCards([card, alternative, secondAlternative]);

    expect(
      wrapper.find('[data-test-id="plan-cards-alternatives-heading"]').text()
    ).toBe('CARD.ALTERNATIVES');

    const alternatives = wrapper.findAll(
      '[data-test-id="plan-card-alternative"]'
    );
    expect(alternatives).toHaveLength(2);
    expect(alternatives[0].text()).toContain('备选方案');
    expect(alternatives[0].text()).toContain('无限流量');
    expect(alternatives[0].text()).toContain('7天');
    expect(alternatives[0].attributes('href')).toBe(alternative.actions[0].uri);
    expect(alternatives[1].attributes('href')).toBe(
      secondAlternative.actions[0].uri
    );
  });

  test('renders a single item without a heading or alternatives', () => {
    const wrapper = mountCards([card]);

    expect(
      wrapper.find('[data-test-id="plan-cards-alternatives-heading"]').exists()
    ).toBe(false);
    expect(
      wrapper.findAll('[data-test-id="plan-card-alternative"]')
    ).toHaveLength(0);
  });

  test('renders no flag when the item carries no country image', () => {
    const wrapper = mountCards([cardWithoutFlag]);

    expect(wrapper.find('img').exists()).toBe(false);
  });

  test('leaves the price fact out of the plan and the alternatives', () => {
    const wrapper = mountCards([card, alternative]);

    expect(wrapper.text()).not.toContain('价格');
    expect(wrapper.text()).not.toContain('USD 16.99');
    expect(wrapper.text()).not.toContain('USD 35.99');
  });
});

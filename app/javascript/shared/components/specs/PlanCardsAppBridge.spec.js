import { mount } from '@vue/test-utils';
import PlanCards from '../PlanCards.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const { sendMessage } = vi.hoisted(() => ({ sendMessage: vi.fn() }));

// The app loads this page top-level: there is no parent iframe, so the
// postback has to go through the native bridge instead.
vi.mock('widget/helpers/utils', async () => {
  const actual = await vi.importActual('widget/helpers/utils');
  return {
    ...actual,
    IFrameHelper: {
      ...actual.IFrameHelper,
      isIFrame: () => false,
      sendMessage,
    },
  };
});

const payload = JSON.stringify({
  type: 'checkout',
  url: 'https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod',
  goods_id: '13',
  sku_id: '13055',
});

const card = {
  title: 'Japan',
  description: '7 days in Japan.',
  media_url: '',
  badge: 'Best match',
  facts: [
    { icon: 'wifi', label: 'Data', value: '10 GB' },
    { icon: 'calendar', label: 'Validity', value: '7 days' },
  ],
  actions: [{ type: 'postback', text: 'Japan 7 days 10GB', payload }],
};

describe('PlanCards app bridge', () => {
  afterEach(() => {
    delete window.NovyroBridge;
  });

  test('hands a postback to the native bridge when the page is top-level', async () => {
    window.NovyroBridge = { postMessage: vi.fn() };
    const wrapper = mount(PlanCards, { props: { items: [card] } });

    await wrapper.find('[data-test-id="plan-card-cta"]').trigger('click');

    expect(window.NovyroBridge.postMessage).toHaveBeenCalledWith(
      `novyro-customer-service-action:${payload}`
    );
    expect(sendMessage).not.toHaveBeenCalled();
  });
});

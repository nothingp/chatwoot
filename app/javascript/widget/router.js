import { createRouter, createWebHashHistory } from 'vue-router';
import ViewWithHeader from './components/layouts/ViewWithHeader.vue';
import store from './store';

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    {
      path: '/unread-messages',
      name: 'unread-messages',
      component: () => import('./views/UnreadMessages.vue'),
    },
    {
      path: '/campaigns',
      name: 'campaigns',
      component: () => import('./views/Campaigns.vue'),
    },
    {
      path: '/',
      component: ViewWithHeader,
      children: [
        {
          // 默认直接落到会话页。首页那张「在线状态 / Start Conversation」卡片对 AI 全接管的
          // 场景只是多一层点击，客户首访看到空白会话也比多点一次更顺。
          // 首页仍保留为 /home —— App.vue 在组件被关闭（未读/活动视图）时会回到它。
          path: '',
          redirect: { name: 'messages' },
        },
        {
          path: '/home',
          name: 'home',
          component: () => import('./views/Home.vue'),
        },
        {
          path: '/prechat-form',
          name: 'prechat-form',
          component: () => import('./views/PreChatForm.vue'),
        },
        {
          path: '/messages',
          name: 'messages',
          component: () => import('./views/Messages.vue'),
        },
        {
          path: '/article',
          name: 'article-viewer',
          component: () => import('./views/ArticleViewer.vue'),
        },
      ],
    },
  ],
});

/**
 * Navigation Guards to Handle Route Transitions
 *
 * Purpose:
 * Prevents duplicate form submissions and API calls during route transitions,
 * especially important in high-latency scenarios.
 *
 * Flow:
 * 1. beforeEach: Sets isUpdatingRoute to true at start of navigation
 * 2. Component buttons/actions check this flag to prevent duplicate actions
 * 3. afterEach: Resets the flag once navigation is complete
 *
 * Implementation note:
 * Handling it globally, so that we can use it across all components
 * to ensure consistent UI behavior during all route transitions.
 *
 * @see https://github.com/chatwoot/chatwoot/issues/10736
 */

router.beforeEach(async (to, from, next) => {
  // Prevent any user interactions during route transition
  await store.dispatch('appConfig/setRouteTransitionState', true);
  next();
});

router.afterEach(() => {
  // Re-enable user interactions after navigation is complete
  store.dispatch('appConfig/setRouteTransitionState', false);
});

export default router;

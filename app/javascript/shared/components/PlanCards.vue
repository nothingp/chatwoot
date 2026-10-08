<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import FluentIcon from 'shared/components/FluentIcon/Index.vue';

const props = defineProps({
  items: {
    type: Array,
    default: () => [],
  },
});

// The card the mobile app renders: the first item is the plan, the rest are the alternatives. The
// price fact the server also sends is deliberately left out -- the app's card does not show it and
// the checkout flow is where the customer reads it.
const STAT_ICONS = ['wifi', 'calendar'];
const ARROW_ICON = 'arrow-right';
const ICON_SIZE = 16;
const FLAG_CLASSES = 'h-4 w-6 shrink-0 rounded-sm object-cover';

const { t } = useI18n();

// Badge, fact labels and values and the call to action are sent already localized and are rendered
// as they arrive; only the alternatives heading is the widget's own copy.
const cards = computed(() =>
  props.items.map(item => ({
    title: item.title,
    badge: item.badge,
    countryImage: item.country_image,
    stats: STAT_ICONS.map(icon =>
      (item.facts || []).find(fact => fact.icon === icon)
    ).filter(Boolean),
    action: (item.actions || [])[0] || {},
  }))
);
const primary = computed(() => cards.value[0]);
// The alternatives are keyed by position, not by checkout uri: nothing in the contract makes two
// cards' uris differ, and a repeated key is not a key.
const alternatives = computed(() => cards.value.slice(1));
</script>

<template>
  <div class="flex w-full flex-col gap-2">
    <div
      v-if="primary"
      class="chat-bubble agent bg-n-background dark:bg-n-solid-3 w-full rounded-lg"
      data-test-id="plan-card-primary"
    >
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <img
            v-if="primary.countryImage"
            :src="primary.countryImage"
            :class="FLAG_CLASSES"
            alt=""
          />
          <span class="text-sm font-medium text-n-slate-12">
            {{ primary.title }}
          </span>
        </div>
        <span
          class="shrink-0 rounded-full bg-n-brand/10 px-2 py-0.5 text-xs font-medium text-n-brand"
          data-test-id="plan-card-badge"
        >
          {{ primary.badge }}
        </span>
      </div>

      <div v-if="primary.stats.length" class="mt-3 flex items-center gap-4">
        <div
          v-for="stat in primary.stats"
          :key="stat.icon"
          class="flex items-center gap-2"
          data-test-id="plan-card-stat"
        >
          <FluentIcon
            :icon="stat.icon"
            :size="ICON_SIZE"
            class="shrink-0 text-n-slate-11"
          />
          <div class="flex flex-col">
            <span class="text-xs text-n-slate-11">{{ stat.label }}</span>
            <span class="text-sm font-medium text-n-slate-12">
              {{ stat.value }}
            </span>
          </div>
        </div>
      </div>

      <!-- `!text-white` is forced on purpose: `.chat-bubble > a` in the widget's _conversation.scss
           is a (0,1,1) selector and outranks a plain `text-white` utility (0,1,0), which paints the
           label in the button's own blue. The arrow inherits the colour via `fill="currentColor"`. -->
      <a
        v-if="primary.action.uri"
        :href="primary.action.uri"
        target="_blank"
        rel="noopener nofollow noreferrer"
        class="mt-3 flex w-full items-center justify-center gap-2 rounded-lg bg-n-brand px-4 py-2 text-sm font-medium !text-white"
        data-test-id="plan-card-cta"
      >
        {{ primary.action.text }}
        <FluentIcon
          :icon="ARROW_ICON"
          :size="ICON_SIZE"
          class="rtl:rotate-180"
        />
      </a>
    </div>

    <div v-if="alternatives.length">
      <p
        class="mb-1 text-xs text-n-slate-11"
        data-test-id="plan-cards-alternatives-heading"
      >
        {{ t('CARD.ALTERNATIVES') }}
      </p>
      <div class="grid grid-cols-2 gap-2">
        <a
          v-for="(alternative, index) in alternatives"
          :key="index"
          :href="alternative.action.uri"
          target="_blank"
          rel="noopener nofollow noreferrer"
          class="bg-n-background dark:bg-n-solid-3 flex flex-col gap-1 rounded-lg p-3"
          data-test-id="plan-card-alternative"
        >
          <span class="text-xs font-medium text-n-slate-11">
            {{ alternative.badge }}
          </span>
          <span
            v-for="stat in alternative.stats"
            :key="stat.icon"
            class="text-sm font-medium text-n-slate-12"
          >
            {{ stat.value }}
          </span>
          <FluentIcon
            :icon="ARROW_ICON"
            :size="ICON_SIZE"
            class="ms-auto text-n-slate-11 rtl:rotate-180"
          />
        </a>
      </div>
    </div>
  </div>
</template>

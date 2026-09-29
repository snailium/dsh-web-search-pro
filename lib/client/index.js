import { WebSearchSettingsController, } from "./form.js";
import { SettingsCard } from "./SettingsCard.js";
import { en, zh } from "./locales.js";
import { ensureStyles } from "./styles.js";
export const name = 'web-search-pro-client';
export const inject = ['slots', 'locale', 'remote', 'remote.credentials', 'configForms'];
export const NS = 'web-search-pro.card';
export function apply(ctx) {
    ensureStyles();
    ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'web-search-pro: settings dictionaries');
    const form = ctx.configForms.get('web-search-pro');
    const controller = new WebSearchSettingsController(form, ctx);
    ctx.effect(() => () => { controller.dispose(); }, 'web-search-pro: settings controller');
    // External bundles contribute configuration to their own Plugins detail
    // page, and only while the Host serves this entry's Config schema.
    ctx.effect(() => ctx.configForms.whileServed(['web-search-pro'], () => ctx.slots.inject('plugins.bundle.config', () => ctx.slots.register({
        name: 'plugins.bundle.config',
        key: 'dsh-web-search-pro',
        locale: NS,
        inject: () => controller.inject(),
    }, SettingsCard))), 'web-search-pro: bundle configuration');
}
//# sourceMappingURL=index.js.map
/* RaBbLE-Aether — Firefox user.js
 * Managed by RaBbLE-OS: config/firefox/user.js
 * Deployed via: ansible/roles/apps/tasks/browsers.yml
 * Applied at every Firefox startup (values are locked until this file is removed).
 */

// ── Theme enablement ────────────────────────────────────────────────
// Allow userChrome.css and userContent.css to load
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Force dark mode for all web content rendering (respects prefers-color-scheme)
user_pref("ui.systemUsesDarkTheme", 1);

// Dark content rendering (0=dark, 1=light, -1=auto)
user_pref("browser.theme.content-theme", 0);

// ── Density ─────────────────────────────────────────────────────────
// Normal density — tab height controlled by userChrome.css, not FF compact mode
user_pref("browser.uidensity", 0);

// ── New tab noise reduction ─────────────────────────────────────────
user_pref("browser.newtabpage.activity-stream.showSponsored",            false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites",    false);
user_pref("browser.newtabpage.activity-stream.feeds.topsites",           false);
user_pref("browser.newtabpage.activity-stream.feeds.section.highlights", false);
user_pref("browser.newtabpage.activity-stream.feeds.snippets",           false);

// ── Fonts ────────────────────────────────────────────────────────────
// Default page fonts to RaBbLE-Aether typefaces
user_pref("font.name.sans-serif.x-western",  "Exo 2");
user_pref("font.name.monospace.x-western",   "Share Tech Mono");
// Minimum font size guard
user_pref("font.minimum-size.x-western",     10);

// ── Scrollbars ───────────────────────────────────────────────────────
// Wayland/GTK overlay scrollbars (thin, matches userContent.css scrollbar-width:thin)
user_pref("widget.gtk.overlay-scrollbars.enabled", true);

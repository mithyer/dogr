// The address of the app in the App Store. It lives in its own file, not in worker.js, because a Worker must export only its
// handler: the current Cloudflare runtime (workerd, also inside `wrangler dev`) refuses a module whose other exports are not
// classes or handlers ("Incorrect type for map entry 'APP_STORE_URL'"). The Worker, the tests and tools/whatsnew.mjs read it here.
// TEST:tests/site.test.mjs[worker: /get]

/**
 * Where /get leads: the app's page in the App Store (the address works in every country, the store picks the storefront).
 * The number is the app record of `dev.dogr.app` in App Store Connect. It answers "not found" until the app is released.
 */
export const APP_STORE_URL = "https://apps.apple.com/app/id6835292499";

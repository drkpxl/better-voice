import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/**
 * Static site for Better Voice, built into ../docs and served at the ROOT of
 * https://voice.baselinemakes.com (Cloudflare Worker static assets; see the repo-root
 * wrangler.jsonc). The default build targets that root domain — BASE_PATH is only for
 * previewing under a subpath (e.g. the retired GitHub project page): BASE_PATH=/better-voice.
 *
 * The Sparkle appcast + release artifacts live in static/ (static/appcast.xml,
 * static/updates/, static/downloads/) so builds emit them into ../docs rather than wiping
 * them — adapter-static cleans its output dir on every build. The downloads/ links on the
 * page point at artifacts that exist only after a release publishes them, so the prerender
 * crawler is told to ignore 404s under that path instead of failing the build.
 */
/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),
	kit: {
		adapter: adapter({
			pages: '../docs',
			assets: '../docs',
			fallback: '404.html',
			precompress: false,
			strict: true
		}),
		paths: {
			base: process.argv.includes('dev') ? '' : (process.env.BASE_PATH ?? '')
		},
		prerender: {
			handleHttpError: ({ path, message }) => {
				// Release artifacts (DMGs, Sparkle zips) are published by release.sh and
				// aren't present in a source-only build.
				if (path.includes('/downloads/') || path.includes('/updates/')) return;
				throw new Error(message);
			}
		}
	}
};

export default config;

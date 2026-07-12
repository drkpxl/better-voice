<script lang="ts">
	import type { Snippet } from 'svelte';

	// A faithful macOS window frame (traffic lights + unified title bar) that scopes the
	// Better Voice app design tokens — system font + brand purple, light or dark. Everything
	// rendered inside a screen component lives in here, so the app UI reads as a real macOS
	// app, independent of the marketing site's serif/mono chrome.
	interface Props {
		title?: string;
		theme?: 'light' | 'dark';
		/** Hide the title bar text (e.g. windows that show their own header). */
		blankTitle?: boolean;
		children: Snippet;
	}

	let { title = '', theme = 'dark', blankTitle = false, children }: Props = $props();
</script>

<div class="bv-window" data-bv-theme={theme}>
	<div class="bv-titlebar">
		<div class="bv-lights" aria-hidden="true">
			<span class="light close"></span>
			<span class="light min"></span>
			<span class="light zoom"></span>
		</div>
		{#if !blankTitle}<span class="bv-title">{title}</span>{/if}
	</div>
	<div class="bv-body">
		{@render children()}
	</div>
</div>

<style>
	.bv-window {
		/* ---- Better Voice app tokens (scoped) ---- */
		--bv-font:
			-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'SF Pro', 'Helvetica Neue', Arial,
			sans-serif;
		--bv-radius: 10px;

		display: flex;
		flex-direction: column;
		font-family: var(--bv-font);
		border-radius: var(--bv-radius);
		overflow: hidden;
		box-shadow:
			0 1px 1px rgba(0, 0, 0, 0.08),
			0 24px 60px -20px rgba(23, 18, 48, 0.45);
		border: 1px solid var(--bv-window-border);
		background: var(--bv-bg);
		color: var(--bv-text);
		text-align: left;
		width: 100%;
	}

	/* ---- Dark theme ---- */
	.bv-window[data-bv-theme='dark'] {
		--bv-accent: #8b7cff;
		--bv-accent-contrast: #ffffff;
		--bv-bg: #1e1e22;
		--bv-titlebar: #323236;
		--bv-surface: #26262b;
		--bv-sidebar: #232327;
		--bv-text: #f2f2f4;
		--bv-text-muted: rgba(255, 255, 255, 0.55);
		--bv-border: #3a3a40;
		--bv-border-strong: #46464d;
		--bv-window-border: #000000;
		--bv-field: #2c2c31;
	}

	/* ---- Light theme ---- */
	.bv-window[data-bv-theme='light'] {
		--bv-accent: #5847d6;
		--bv-accent-contrast: #ffffff;
		--bv-bg: #ececee;
		--bv-titlebar: #e6e6e8;
		--bv-surface: #ffffff;
		--bv-sidebar: #e9e9ea;
		--bv-text: #1d1d1f;
		--bv-text-muted: rgba(0, 0, 0, 0.5);
		--bv-border: #dcdce0;
		--bv-border-strong: #cfcfd4;
		--bv-window-border: rgba(0, 0, 0, 0.12);
		--bv-field: #ffffff;
	}

	.bv-titlebar {
		position: relative;
		display: flex;
		align-items: center;
		height: 38px;
		flex-shrink: 0;
		padding: 0 14px;
		background: var(--bv-titlebar);
		border-bottom: 1px solid var(--bv-border);
	}

	.bv-lights {
		display: flex;
		gap: 8px;
		z-index: 1;
	}

	.light {
		width: 12px;
		height: 12px;
		border-radius: 50%;
		box-shadow: inset 0 0 0 0.5px rgba(0, 0, 0, 0.12);
	}
	.light.close {
		background: #ff5f57;
	}
	.light.min {
		background: #febc2e;
	}
	.light.zoom {
		background: #28c840;
	}

	.bv-title {
		position: absolute;
		inset: 0;
		display: flex;
		align-items: center;
		justify-content: center;
		font-size: 13px;
		font-weight: 600;
		color: var(--bv-text-muted);
		pointer-events: none;
	}

	.bv-body {
		flex: 1;
		min-height: 0;
		display: flex;
		flex-direction: column;
		background: var(--bv-bg);
	}
</style>

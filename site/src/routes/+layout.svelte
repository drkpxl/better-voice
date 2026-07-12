<script lang="ts">
	import '../app.css';
	import { base } from '$app/paths';
	import Waveform from '$lib/components/Waveform.svelte';

	let { children } = $props();
</script>

<div class="site">
	<header class="header">
		<div class="container header-inner">
			<a class="brand" href="{base}/">
				<Waveform height={22} color="var(--color-accent)" />
				<span class="brand-name">Better Voice</span>
			</a>
			<nav class="nav" aria-label="Main navigation">
				<a href="{base}/#features">Features</a>
				<a class="nav-cta" href="{base}/#download">Download</a>
			</nav>
		</div>
	</header>

	<main>
		{@render children()}
	</main>

	<footer class="footer">
		<div class="container footer-inner">
			<span class="brand">
				<Waveform height={16} color="var(--color-text-muted)" />
				<span class="footer-name">Better Voice</span>
			</span>
			<p class="footer-note">
				Dictation &amp; AI meeting notes for macOS, saved to Apple Notes. A
				<a href="https://baselinemakes.com" target="_blank" rel="noopener noreferrer">Baseline Makes</a>
				project. © 2026.
			</p>
		</div>
	</footer>
</div>

<style>
	.site {
		display: flex;
		flex-direction: column;
		min-height: 100vh;
	}

	main {
		flex: 1;
	}

	.header {
		position: sticky;
		top: 0;
		z-index: 100;
		background-color: color-mix(in srgb, var(--color-bg) 82%, transparent);
		backdrop-filter: saturate(180%) blur(12px);
		border-bottom: 1px solid var(--color-border-light);
	}

	.header-inner,
	.footer-inner {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-md);
	}

	.header-inner {
		padding-block: var(--space-md);
	}

	.brand {
		display: inline-flex;
		align-items: center;
		gap: 0.55rem;
		text-decoration: none;
		color: var(--color-text);
	}

	.brand-name {
		font-weight: var(--weight-black);
		font-size: 1.15rem;
		letter-spacing: -0.02em;
	}

	.nav {
		display: flex;
		align-items: center;
		gap: var(--space-md);
	}

	.nav a {
		font-size: 0.9375rem;
		color: var(--color-text-muted);
		text-decoration: none;
		transition: color var(--transition-fast);
	}

	.nav a:hover {
		color: var(--color-accent);
	}

	.nav-cta {
		padding: 0.4rem 0.9rem;
		border-radius: var(--border-radius);
		background-color: var(--color-accent);
		color: #fff !important;
		font-weight: 500;
	}

	.nav-cta:hover {
		background-color: var(--color-accent-hover);
	}

	.footer {
		margin-top: var(--space-2xl);
		border-top: 1px solid var(--color-border-light);
		background-color: var(--color-bg-alt);
	}

	.footer-inner {
		padding-block: var(--space-lg);
		flex-wrap: wrap;
	}

	.footer-name {
		font-weight: var(--weight-bold);
		color: var(--color-text-muted);
	}

	.footer-note {
		font-size: 0.8125rem;
		color: var(--color-text-muted);
		margin: 0;
	}

	@media (max-width: 560px) {
		.nav {
			gap: var(--space-sm);
		}
		.nav a {
			font-size: 0.8125rem;
		}
	}
</style>

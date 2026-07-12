<script lang="ts">
	// Better Voice brand mark: a 5-bar waveform with the app's exact height ratios
	// (6 / 13 / 9 / 16 / 7 — see BrandColor.swift / BrandWaveform in the app).
	interface Props {
		height?: number; // px height of the tallest bar
		color?: string; // any CSS color; defaults to the brand accent
		animated?: boolean; // gentle "listening" bounce
	}

	let { height = 34, color = 'var(--bv-accent)', animated = false }: Props = $props();

	const ratios = [6, 13, 9, 16, 7];
	const maxRatio = Math.max(...ratios);
	const barWidth = $derived(height * 0.16);
	const gap = $derived(barWidth * 0.78);
</script>

<span
	class="waveform"
	class:animated
	style="--wf-height:{height}px; --wf-bar:{barWidth}px; --wf-gap:{gap}px; --wf-color:{color};"
	aria-hidden="true"
>
	{#each ratios as ratio, i (i)}
		<span class="bar" style="height:{(ratio / maxRatio) * 100}%; --i:{i};"></span>
	{/each}
</span>

<style>
	.waveform {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: var(--wf-gap);
		height: var(--wf-height);
	}

	.bar {
		width: var(--wf-bar);
		background-color: var(--wf-color);
		border-radius: 999px;
		flex-shrink: 0;
	}

	.animated .bar {
		animation: pulse 1.1s ease-in-out infinite;
		animation-delay: calc(var(--i) * 0.09s);
		transform-origin: center;
	}

	@keyframes pulse {
		0%,
		100% {
			transform: scaleY(0.55);
		}
		50% {
			transform: scaleY(1);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.animated .bar {
			animation: none;
		}
	}
</style>

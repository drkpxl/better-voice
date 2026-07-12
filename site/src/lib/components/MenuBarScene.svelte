<script lang="ts">
	// Static, display-only recreation of the Better Voice macOS menu-bar
	// dropdown + dictation recording indicator. No interactivity.
	import Waveform from './Waveform.svelte';

	interface Props {
		/** Extra classes to place on the scene root, if needed by a gallery. */
		class?: string;
	}

	let { class: className = '' }: Props = $props();

	// Faux status-bar glyphs (order left -> right before the app item).
	const statusGlyphs = ['wifi', 'battery'] as const;

	// Dropdown rows, in exact order. `kind` drives rendering.
	type Row =
		| { kind: 'header'; label: string }
		| { kind: 'divider' }
		| { kind: 'item'; label: string; check?: boolean; hovered?: boolean }
		| { kind: 'shortcut'; label: string; shortcut: string };

	const rows: Row[] = [
		{ kind: 'header', label: 'Better Voice' },
		{ kind: 'divider' },
		{ kind: 'item', label: 'Global hotkey monitoring: Authorized', check: true },
		{ kind: 'item', label: 'Text injection (cursor): Authorized', check: true },
		{ kind: 'item', label: 'Microphone: Authorized', check: true },
		{ kind: 'divider' },
		{ kind: 'item', label: 'Open Better Voice', hovered: true },
		{ kind: 'item', label: 'Set Hotkey…' },
		{ kind: 'divider' },
		{ kind: 'item', label: 'Start Meeting…' },
		{ kind: 'divider' },
		{ kind: 'item', label: 'Welcome / Setup Guide' },
		{ kind: 'divider' },
		{ kind: 'shortcut', label: 'Settings…', shortcut: '⌘,' },
		{ kind: 'shortcut', label: 'Quit', shortcut: '⌘Q' }
	];
</script>

<div class="scene {className}">
	<!-- 1. TOP MENU BAR -->
	<div class="menubar">
		<div class="menubar-right">
			{#each statusGlyphs as glyph, i (i)}
				{#if glyph === 'wifi'}
					<svg class="glyph" viewBox="0 0 18 14" width="17" height="13" aria-hidden="true">
						<path
							d="M9 12.2a1.4 1.4 0 1 0 0-2.8 1.4 1.4 0 0 0 0 2.8Z"
							fill="currentColor"
						/>
						<path
							d="M4.4 7.2a6.6 6.6 0 0 1 9.2 0"
							fill="none"
							stroke="currentColor"
							stroke-width="1.6"
							stroke-linecap="round"
						/>
						<path
							d="M1.8 4.4a10.4 10.4 0 0 1 14.4 0"
							fill="none"
							stroke="currentColor"
							stroke-width="1.6"
							stroke-linecap="round"
						/>
					</svg>
				{:else}
					<svg class="glyph" viewBox="0 0 26 14" width="25" height="13" aria-hidden="true">
						<rect
							x="1"
							y="2.5"
							width="21"
							height="9"
							rx="2.6"
							fill="none"
							stroke="currentColor"
							stroke-opacity="0.55"
							stroke-width="1.1"
						/>
						<rect x="2.6" y="4" width="16" height="6" rx="1.3" fill="currentColor" />
						<rect x="23" y="5" width="1.7" height="4" rx="0.85" fill="currentColor" fill-opacity="0.55" />
					</svg>
				{/if}
			{/each}

			<span class="clock">9:41</span>

			<!-- Better Voice status item -->
			<span class="app-item">
				<Waveform height={14} color="#fff" />
				<span class="rec-dot" aria-hidden="true">●</span>
			</span>
		</div>
	</div>

	<!-- 3. RECORDING INDICATOR (hanging from top edge, center-left) -->
	<div class="rec-indicator">
		<Waveform height={18} color="#fff" animated={true} />
	</div>

	<!-- 2. DROPDOWN MENU (below the status item, toward the right) -->
	<div class="menu" role="menu">
		{#each rows as row, i (i)}
			{#if row.kind === 'divider'}
				<div class="divider" aria-hidden="true"></div>
			{:else if row.kind === 'header'}
				<div class="row header">{row.label}</div>
			{:else if row.kind === 'shortcut'}
				<div class="row item flex">
					<span class="label">{row.label}</span>
					<span class="shortcut">{row.shortcut}</span>
				</div>
			{:else}
				<div class="row item" class:hovered={row.hovered}>
					{#if row.check}<span class="check">✓</span>{/if}<span class="label">{row.label}</span>
				</div>
			{/if}
		{/each}
	</div>
</div>

<style>
	.scene {
		/* Scoped tokens */
		--bv-accent: #8b7cff;
		--bv-green: #34c759;
		--bv-text: rgba(255, 255, 255, 0.92);
		--bv-muted: rgba(255, 255, 255, 0.5);
		--bv-divider: rgba(255, 255, 255, 0.12);

		position: relative;
		width: 100%;
		min-height: 560px;
		border-radius: 12px;
		overflow: hidden;
		background:
			radial-gradient(120% 90% at 78% 0%, rgba(139, 124, 255, 0.22), transparent 55%),
			linear-gradient(160deg, #2b2740 0%, #171622 55%, #0c0b12 100%);
		font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
		color: var(--bv-text);
		-webkit-font-smoothing: antialiased;
	}

	/* 1. MENU BAR */
	.menubar {
		position: absolute;
		inset: 0 0 auto 0;
		height: 28px;
		display: flex;
		align-items: center;
		justify-content: flex-end;
		padding: 0 clamp(6px, 2%, 14px);
		background: rgba(0, 0, 0, 0.35);
		backdrop-filter: blur(12px);
		-webkit-backdrop-filter: blur(12px);
		z-index: 3;
	}

	.menubar-right {
		display: flex;
		align-items: center;
		gap: clamp(6px, 1.6%, 12px);
		color: #fff;
	}

	.glyph {
		display: block;
		opacity: 0.92;
	}

	.clock {
		font-size: 13px;
		font-weight: 500;
		letter-spacing: 0.2px;
		white-space: nowrap;
	}

	.app-item {
		display: inline-flex;
		align-items: center;
		gap: 3px;
		padding-left: 2px;
	}

	.rec-dot {
		color: #ff453a;
		font-size: 8px;
		line-height: 1;
		margin-top: -6px;
		margin-left: -1px;
	}

	/* Hide the clock when the container gets very narrow */
	@container (max-width: 340px) {
		.clock {
			display: none;
		}
	}
	@media (max-width: 360px) {
		.clock {
			display: none;
		}
	}

	/* 3. RECORDING INDICATOR */
	.rec-indicator {
		position: absolute;
		top: 28px;
		left: clamp(18px, 12%, 90px);
		width: min(150px, 44%);
		height: 26px;
		display: flex;
		align-items: center;
		justify-content: center;
		background: #000;
		border-radius: 0 0 12px 12px;
		box-shadow: 0 6px 18px rgba(0, 0, 0, 0.45);
		z-index: 2;
	}

	/* 2. DROPDOWN MENU */
	.menu {
		position: absolute;
		top: 34px;
		right: clamp(6px, 3%, 18px);
		min-width: 300px;
		max-width: calc(100% - 24px);
		padding: 6px;
		border-radius: 8px;
		background: rgba(40, 40, 44, 0.92);
		backdrop-filter: blur(20px);
		-webkit-backdrop-filter: blur(20px);
		border: 1px solid var(--bv-divider);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.5);
		z-index: 4;
	}

	.divider {
		height: 1px;
		background: var(--bv-divider);
		margin: 4px 6px;
	}

	.row {
		font-size: 13px;
		line-height: 1.35;
		padding: 4px 10px;
		border-radius: 5px;
		color: var(--bv-text);
	}

	.row.header {
		font-size: 11px;
		font-weight: 600;
		color: var(--bv-muted);
		letter-spacing: 0.2px;
	}

	.row.item {
		display: flex;
		align-items: center;
		gap: 6px;
	}

	.row.item.flex {
		justify-content: space-between;
	}

	.row.item.flex .label {
		flex: 1 1 auto;
	}

	.check {
		color: var(--bv-green);
		font-weight: 700;
		font-size: 12px;
		flex-shrink: 0;
	}

	.label {
		min-width: 0;
	}

	.shortcut {
		color: var(--bv-muted);
		font-size: 12px;
		flex-shrink: 0;
		padding-left: 12px;
	}

	.row.item.hovered {
		background: var(--bv-accent);
		color: #fff;
	}

	@media (prefers-reduced-motion: reduce) {
		/* Waveform handles its own reduced-motion; nothing else animates. */
	}
</style>

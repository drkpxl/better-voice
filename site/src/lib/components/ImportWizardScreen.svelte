<script lang="ts">
	// Better Voice — Import wizard (static, display-only marketing/prototype asset).
	// Recreates the wizard's four steps in HTML/CSS inside the shared macOS AppWindow
	// frame: import a recording, transcribe & find speakers, name the speakers, and
	// a done screen once the notes have been created. No real interactivity; selected
	// states are baked in.
	import AppWindow from './AppWindow.svelte';
	import Waveform from './Waveform.svelte';

	let { step = 'setup' }: { step?: 'setup' | 'progress' | 'speakers' | 'done' } = $props();

	// Speaker cards for the showcase step.
	const speakers = [
		{
			label: 'Speaker 1',
			quote: 'I think we can ship the beta by Friday if the API work lands.',
			value: 'Priya',
			recognized: true
		},
		{
			label: 'Speaker 2',
			quote: 'Let me pull the latest error rates before we commit.',
			value: 'Sam',
			recognized: true
		},
		{
			label: 'Speaker 3',
			quote: 'Sounds good — I’ll take the migration.',
			value: '',
			recognized: false
		}
	];
</script>

<AppWindow title="Better Voice" theme="dark">
	<div class="wizard">
		{#if step === 'setup'}
			<!-- ================= STEP 1 · Import a recording ================= -->
			<div class="content">
				<div class="header">
					<span class="eyebrow">Step 1 of 4</span>
					<h1 class="title">Import a recording</h1>
					<p class="subtitle">
						Transcribe an audio file, or paste a transcript you already have.
					</p>
				</div>

				<!-- source segmented control -->
				<div class="segmented full">
					<span class="seg selected">Audio file</span>
					<span class="seg">Paste transcript</span>
				</div>

				<!-- drop zone -->
				<div class="dropzone">
					<span class="drop-icon">
						<!-- waveform.badge.plus (approximated) -->
						<Waveform height={34} color="var(--bv-accent)" animated={false} />
						<span class="plus-badge" aria-hidden="true">
							<svg viewBox="0 0 24 24" width="14" height="14" fill="none">
								<circle cx="12" cy="12" r="11" fill="var(--bv-accent)" />
								<path
									d="M12 7v10M7 12h10"
									stroke="var(--bv-accent-contrast)"
									stroke-width="2.2"
									stroke-linecap="round"
								/>
							</svg>
						</span>
					</span>
					<p class="drop-text">Drop an audio file here</p>
					<span class="btn bordered">Choose File…</span>
				</div>

				<!-- speaker mode -->
				<div class="field-block">
					<span class="field-label">Who's talking?</span>
					<div class="segmented full">
						<span class="seg selected">Multiple speakers</span>
						<span class="seg">Just me / single speaker</span>
					</div>
				</div>
			</div>

			<div class="footer">
				<span class="spacer"></span>
				<span class="btn prominent">Continue</span>
			</div>
		{:else if step === 'progress'}
			<!-- ================= STEP 2 · Transcribing ================= -->
			<div class="content progress-content">
				<div class="header">
					<span class="eyebrow">Step 2 of 4</span>
					<h1 class="title">Listening back to your recording</h1>
					<p class="subtitle">This all happens on your Mac — nothing leaves the machine.</p>
				</div>

				<div class="progress-list">
					<div class="progress-row done">
						<span class="progress-check" aria-hidden="true">✓</span>
						<span class="progress-label">Transcribing the audio</span>
					</div>
					<div class="progress-row active">
						<span class="progress-spinner" aria-hidden="true"></span>
						<span class="progress-label">Telling the speakers apart</span>
					</div>
					<div class="progress-row pending">
						<span class="progress-dot" aria-hidden="true"></span>
						<span class="progress-label">Writing the summary</span>
					</div>
				</div>
			</div>
		{:else if step === 'speakers'}
			<!-- ================= STEP 3 · Name the speakers ================= -->
			<div class="header-block">
				<div class="header header-row">
					<div>
						<span class="eyebrow">Step 3 of 4</span>
						<h1 class="title">Name the speakers</h1>
						<p class="subtitle">
							Match each voice to a name. You can leave any blank — a summary is
							generated either way.
						</p>
					</div>
					<span class="menu-picker">
						Meeting type
						<svg viewBox="0 0 12 12" width="10" height="10" fill="none" aria-hidden="true">
							<path
								d="M2.5 4.5 6 8l3.5-3.5"
								stroke="currentColor"
								stroke-width="1.4"
								stroke-linecap="round"
								stroke-linejoin="round"
							/>
						</svg>
					</span>
				</div>
			</div>

			<div class="divider"></div>

			<div class="speaker-scroll">
				{#each speakers as sp, i (i)}
					<div class="speaker-card">
						<p class="quote">“{sp.quote}”</p>
						<div class="name-row">
							<span class="speaker-label">{sp.label}</span>
							<span class="text-field" class:placeholder={!sp.value}>
								{#if sp.value}{sp.value}{:else}is…&nbsp;&nbsp;(type a name){/if}
							</span>
						</div>
						{#if sp.recognized}
							<p class="hint">
								Recognized from a previous meeting — edit if this is wrong.
							</p>
						{/if}
					</div>
				{/each}
			</div>

			<div class="divider"></div>

			<div class="footer">
				<span class="spacer"></span>
				<span class="btn prominent">Continue</span>
			</div>
		{:else}
			<!-- ================= STEP 4 · Done ================= -->
			<div class="done-content">
				<span class="done-badge" aria-hidden="true">
					<svg viewBox="0 0 24 24" width="30" height="30" fill="none" aria-hidden="true">
						<circle cx="12" cy="12" r="11" fill="var(--bv-accent)" />
						<path
							d="M7.5 12.5 10.3 15.3 16.5 9"
							stroke="var(--bv-accent-contrast)"
							stroke-width="2.2"
							stroke-linecap="round"
							stroke-linejoin="round"
						/>
					</svg>
				</span>
				<h1 class="done-title">Added to Notes</h1>
				<p class="done-subtitle">
					Opened the summary — <strong>“Jun 18th - Q3 Roadmap Sync”</strong> is in your
					Meetings folder, transcript included.
				</p>
			</div>

			<div class="divider"></div>

			<div class="footer">
				<span class="spacer"></span>
				<span class="btn prominent">Done</span>
			</div>
		{/if}
	</div>
</AppWindow>

<style>
	.wizard {
		display: flex;
		flex-direction: column;
		height: 560px;
		min-height: 0;
		font-size: 13px;
		color: var(--bv-text);
	}

	/* ---- shared layout ---- */
	.content {
		flex: 1;
		min-height: 0;
		display: flex;
		flex-direction: column;
		gap: 20px;
		padding: 28px;
		overflow: hidden;
	}

	.header-block {
		padding: 28px 28px 0;
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.header {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.header-row {
		flex-direction: row;
		align-items: flex-start;
		justify-content: space-between;
		gap: 16px;
	}

	.eyebrow {
		font-size: 10px;
		font-weight: 600;
		color: var(--bv-accent);
		text-transform: uppercase;
		letter-spacing: 0.08em;
	}

	.title {
		font-size: 17px;
		font-weight: 600;
		margin: 2px 0 0;
		line-height: 1.2;
	}

	.subtitle {
		font-size: 12px;
		color: var(--bv-text-muted);
		margin: 0;
		line-height: 1.4;
		max-width: 52ch;
	}

	/* ---- segmented control (sliding selected pill via inset shadow layers) ---- */
	.segmented {
		display: inline-flex;
		padding: 2px;
		background: var(--bv-field);
		border: 1px solid var(--bv-border);
		border-radius: 8px;
		gap: 2px;
	}

	.segmented.full {
		display: flex;
		width: 100%;
	}

	.seg {
		flex: 1;
		text-align: center;
		padding: 5px 12px;
		font-size: 12px;
		font-weight: 500;
		color: var(--bv-text-muted);
		border-radius: 6px;
		white-space: nowrap;
		user-select: none;
	}

	.seg.selected {
		background: var(--bv-accent);
		color: var(--bv-accent-contrast);
		box-shadow: 0 1px 2px rgba(0, 0, 0, 0.25);
	}

	/* ---- drop zone ---- */
	.dropzone {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 12px;
		width: 100%;
		padding: 34px 20px;
		border-radius: 12px;
		background: var(--bv-surface);
		border: 2px dashed rgba(139, 124, 255, 0.5);
	}

	.drop-icon {
		position: relative;
		display: inline-flex;
	}

	.plus-badge {
		position: absolute;
		right: -8px;
		bottom: -4px;
		display: inline-flex;
		background: var(--bv-surface);
		border-radius: 50%;
		line-height: 0;
	}

	.drop-text {
		margin: 0;
		font-size: 12px;
		color: var(--bv-text-muted);
	}

	/* ---- buttons ---- */
	.btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		padding: 6px 14px;
		font-size: 12px;
		font-weight: 500;
		border-radius: 7px;
		white-space: nowrap;
		user-select: none;
	}

	.btn.bordered {
		background: var(--bv-field);
		border: 1px solid var(--bv-border-strong, var(--bv-border));
		color: var(--bv-text);
	}

	.btn.prominent {
		background: var(--bv-accent);
		color: var(--bv-accent-contrast);
		font-weight: 600;
		padding: 6px 18px;
		box-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
	}

	/* ---- field block ---- */
	.field-block {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.field-label {
		font-size: 11px;
		font-weight: 600;
	}

	/* ---- footer ---- */
	.footer {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 14px 28px;
		flex-shrink: 0;
	}

	.spacer {
		flex: 1;
	}

	.divider {
		height: 1px;
		background: var(--bv-border);
		flex-shrink: 0;
	}

	/* ---- meeting-type menu picker ---- */
	.menu-picker {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		flex-shrink: 0;
		padding: 5px 10px;
		font-size: 12px;
		font-weight: 500;
		color: var(--bv-text);
		background: var(--bv-field);
		border: 1px solid var(--bv-border-strong, var(--bv-border));
		border-radius: 7px;
	}

	.menu-picker svg {
		color: var(--bv-text-muted);
	}

	/* ---- speaker cards ---- */
	.speaker-scroll {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding: 14px 28px;
	}

	.speaker-card {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 14px;
		background: var(--bv-surface);
		border-radius: 10px;
	}

	.quote {
		margin: 0;
		font-size: 12px;
		font-style: italic;
		color: var(--bv-text-muted);
		line-height: 1.45;
	}

	.name-row {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.speaker-label {
		flex-shrink: 0;
		width: 78px;
		font-size: 11px;
		font-weight: 600;
		color: var(--bv-accent);
	}

	.text-field {
		flex: 1;
		padding: 6px 10px;
		font-size: 12px;
		color: var(--bv-text);
		background: var(--bv-field);
		border: 1px solid var(--bv-border);
		border-radius: 7px;
	}

	.text-field.placeholder {
		color: var(--bv-text-muted);
	}

	.hint {
		margin: 0;
		font-size: 10px;
		color: var(--bv-text-muted);
		line-height: 1.4;
	}

	/* ---- progress step ---- */
	.progress-content {
		justify-content: center;
	}

	.progress-list {
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding: 4px 0;
	}

	.progress-row {
		display: flex;
		align-items: center;
		gap: 12px;
		font-size: 13px;
	}

	.progress-row.done .progress-label {
		color: var(--bv-text-muted);
	}

	.progress-row.pending .progress-label {
		color: var(--bv-text-muted);
	}

	.progress-check {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 18px;
		height: 18px;
		flex-shrink: 0;
		border-radius: 50%;
		background: var(--bv-accent);
		color: var(--bv-accent-contrast);
		font-size: 11px;
		font-weight: 700;
	}

	.progress-spinner {
		width: 14px;
		height: 14px;
		flex-shrink: 0;
		margin: 0 2px;
		border-radius: 50%;
		border: 2px solid var(--bv-border-strong, var(--bv-border));
		border-top-color: var(--bv-accent);
		animation: spin 0.8s linear infinite;
	}

	.progress-dot {
		width: 8px;
		height: 8px;
		flex-shrink: 0;
		margin: 0 5px;
		border-radius: 50%;
		background: var(--bv-border-strong, var(--bv-border));
	}

	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.progress-spinner {
			animation: none;
		}
	}

	/* ---- done step ---- */
	.done-content {
		flex: 1;
		min-height: 0;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 12px;
		padding: 28px;
		text-align: center;
	}

	.done-badge {
		display: inline-flex;
	}

	.done-title {
		font-size: 18px;
		font-weight: 700;
		margin: 0;
	}

	.done-subtitle {
		font-size: 12.5px;
		color: var(--bv-text-muted);
		line-height: 1.5;
		max-width: 40ch;
		margin: 0;
	}

	.done-subtitle strong {
		color: var(--bv-text);
	}
</style>

<script lang="ts">
	// Static, display-only recreation of the Better Voice macOS "Settings" window —
	// a grouped inset form (like modern System Settings). LIGHT theme only.
	import AppWindow from './AppWindow.svelte';
</script>

<AppWindow title="Settings" theme="light">
	<div class="settings">
		<div class="form" role="presentation">
			<!-- 1. Connection -->
			<section class="group">
				<span class="group-header">Connection</span>
				<div class="card">
					<div class="row">
						<span class="row-label">Status</span>
						<span class="spacer"></span>
						<span class="status-ok">Connected</span>
						<button class="btn" type="button">Check</button>
					</div>
				</div>
				<p class="caption">
					Reflects whichever of Dictation Polish / Summarization below are enabled — red if
					either is unreachable.
				</p>
			</section>

			<!-- 2. Dictation Polish -->
			<section class="group">
				<span class="group-header">Dictation Polish</span>
				<div class="card">
					<div class="row">
						<span class="row-label">Provider</span>
						<span class="spacer"></span>
						<button class="popup" type="button">
							<span>Ollama</span>
							<svg class="chevrons" viewBox="0 0 12 16" aria-hidden="true">
								<path d="M3.5 6.5 6 4l2.5 2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
								<path d="M3.5 9.5 6 12l2.5-2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
							</svg>
						</button>
					</div>
					<div class="divider"></div>
					<div class="row">
						<span class="row-label">Endpoint</span>
						<span class="spacer"></span>
						<input class="field endpoint" type="text" value="http://localhost:11434" readonly />
					</div>
					<div class="divider"></div>
					<div class="row">
						<span class="row-label">Model</span>
						<span class="spacer"></span>
						<button class="popup" type="button">
							<span>qwen3.5:4b-mlx</span>
							<svg class="chevrons" viewBox="0 0 12 16" aria-hidden="true">
								<path d="M3.5 6.5 6 4l2.5 2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
								<path d="M3.5 9.5 6 12l2.5-2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
							</svg>
						</button>
						<button class="btn" type="button">Load Models</button>
					</div>
				</div>
				<p class="caption">
					Cleans up what you dictate before it's inserted. A small model here makes dictation
					inject faster.
				</p>
			</section>

			<!-- 3. Summarization -->
			<section class="group">
				<span class="group-header">Summarization</span>
				<div class="card">
					<div class="row">
						<span class="row-label">Summarize meetings</span>
						<span class="spacer"></span>
						<span class="switch on" role="switch" aria-checked="true" aria-label="Summarize meetings">
							<span class="knob"></span>
						</span>
					</div>
					<div class="divider"></div>
					<div class="row">
						<span class="row-label">Provider</span>
						<span class="spacer"></span>
						<button class="popup" type="button">
							<span>Apple on-device</span>
							<svg class="chevrons" viewBox="0 0 12 16" aria-hidden="true">
								<path d="M3.5 6.5 6 4l2.5 2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
								<path d="M3.5 9.5 6 12l2.5-2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
							</svg>
						</button>
					</div>
					<div class="divider"></div>
					<div class="row inset-caption-row">
						<p class="inset-caption">
							Uses Apple Intelligence on this Mac — nothing to install. Requires Apple
							Intelligence to be enabled in System Settings.
						</p>
					</div>
					<div class="divider"></div>
					<div class="row">
						<span class="row-label">Context window (num_ctx)</span>
						<span class="spacer"></span>
						<input class="field number" type="text" value="8192" readonly />
					</div>
				</div>
				<p class="caption">
					Long meetings need a large-context model. A tiny default model may truncate.
				</p>
			</section>

			<!-- 4. Meetings -->
			<section class="group">
				<span class="group-header">Meetings</span>
				<div class="card">
					<div class="row">
						<span class="row-label">Your name</span>
						<span class="spacer"></span>
						<input class="field name" type="text" value="You" placeholder="Your name" readonly />
					</div>
					<div class="divider"></div>
					<div class="row inset-caption-row">
						<p class="inset-caption">
							Appears as the speaker label for your own voice in transcripts and summaries.
							Leave blank to use &ldquo;You&rdquo;.
						</p>
					</div>
					<div class="divider"></div>
					<div class="row">
						<span class="row-label">Default meeting type</span>
						<span class="spacer"></span>
						<button class="popup" type="button">
							<span>General</span>
							<svg class="chevrons" viewBox="0 0 12 16" aria-hidden="true">
								<path d="M3.5 6.5 6 4l2.5 2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
								<path d="M3.5 9.5 6 12l2.5-2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
							</svg>
						</button>
					</div>
				</div>
			</section>

			<!-- 5. Apple Notes destination -->
			<section class="group">
				<span class="group-header">Apple Notes</span>
				<div class="card">
					<div class="row">
						<span class="row-label">Summaries folder</span>
						<span class="spacer"></span>
						<span class="path">Meetings</span>
						<button class="btn" type="button">Change...</button>
					</div>
					<div class="divider"></div>
					<div class="row">
						<span class="row-label">Transcripts folder</span>
						<span class="spacer"></span>
						<span class="path">Meetings/Transcripts</span>
						<button class="btn" type="button">Change...</button>
					</div>
					<div class="divider"></div>
					<div class="row inset-caption-row">
						<p class="inset-caption">
							Better Voice creates a note in each folder and opens the summary — it never
							reads your existing notes.
						</p>
					</div>
				</div>
				<p class="caption">
					Requires Automation access to Notes, granted once on first run.
				</p>
			</section>

			<!-- 6. Hotkey -->
			<section class="group">
				<span class="group-header">Hotkey</span>
				<div class="card">
					<div class="row">
						<span class="row-label">Dictation hotkey</span>
						<span class="spacer"></span>
						<span class="hotkey">Right Option</span>
						<button class="btn" type="button">Change...</button>
					</div>
				</div>
			</section>
		</div>

		<!-- Footer -->
		<footer class="footer">
			<button class="btn" type="button">Cancel</button>
			<button class="btn btn-default" type="button">Save</button>
		</footer>
	</div>
</AppWindow>

<style>
	.settings {
		display: flex;
		flex-direction: column;
		height: 560px;
		min-height: 0;
	}

	.form {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		padding: 20px;
		display: flex;
		flex-direction: column;
		gap: 18px;
		background: var(--bv-bg);
	}

	/* ---- Group (label above a card) ---- */
	.group {
		display: flex;
		flex-direction: column;
	}

	.group-header {
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.03em;
		color: var(--bv-text-muted);
		margin: 0 0 6px 10px;
	}

	.card {
		background: var(--bv-surface);
		border: 1px solid var(--bv-border);
		border-radius: 10px;
		overflow: hidden;
	}

	.row {
		display: flex;
		align-items: center;
		gap: 10px;
		min-height: 40px;
		padding: 7px 12px;
	}

	.spacer {
		flex: 1;
	}

	.divider {
		height: 1px;
		background: var(--bv-border);
		margin-left: 12px;
	}

	.row-label {
		font-size: 13px;
		color: var(--bv-text);
	}

	.caption {
		font-size: 11px;
		line-height: 1.35;
		color: var(--bv-text-muted);
		margin: 6px 10px 0 10px;
	}

	.inset-caption-row {
		padding-top: 2px;
		padding-bottom: 4px;
	}

	.inset-caption {
		font-size: 11px;
		line-height: 1.35;
		color: var(--bv-text-muted);
		margin: 0;
	}

	/* ---- Connection status ---- */
	.status-ok {
		font-size: 13px;
		font-weight: 600;
		color: #34c759;
	}

	/* ---- Bordered (push) button ---- */
	.btn {
		font-family: inherit;
		font-size: 12px;
		color: var(--bv-text);
		background: var(--bv-field);
		border: 1px solid var(--bv-border-strong);
		border-radius: 6px;
		padding: 4px 11px;
		cursor: default;
		white-space: nowrap;
		box-shadow: 0 1px 0 rgba(0, 0, 0, 0.02);
	}

	.btn-default {
		background: var(--bv-accent);
		border-color: var(--bv-accent);
		color: var(--bv-accent-contrast);
		font-weight: 500;
	}

	/* ---- Popup (select-styled) button ---- */
	.popup {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font-family: inherit;
		font-size: 13px;
		color: var(--bv-text);
		background: var(--bv-field);
		border: 1px solid var(--bv-border-strong);
		border-radius: 6px;
		padding: 4px 6px 4px 10px;
		cursor: default;
		white-space: nowrap;
		box-shadow: 0 1px 0 rgba(0, 0, 0, 0.02);
	}

	.chevrons {
		width: 12px;
		height: 16px;
		flex-shrink: 0;
		color: var(--bv-accent);
	}

	/* ---- Text / number fields ---- */
	.field {
		font-family: inherit;
		font-size: 13px;
		color: var(--bv-text);
		background: var(--bv-field);
		border: 1px solid var(--bv-border);
		border-radius: 5px;
		padding: 4px 8px;
		outline: none;
	}

	.endpoint {
		width: 220px;
		font-family:
			ui-monospace, 'SF Mono', Menlo, Monaco, 'Cascadia Code', monospace;
		font-size: 12px;
	}

	.name {
		width: 200px;
	}

	.number {
		width: 90px;
		text-align: right;
		font-variant-numeric: tabular-nums;
	}

	/* ---- macOS switch ---- */
	.switch {
		position: relative;
		display: inline-block;
		width: 38px;
		height: 22px;
		border-radius: 11px;
		background: var(--bv-border-strong);
		flex-shrink: 0;
		transition: background 0.15s ease;
	}

	.switch.on {
		background: var(--bv-accent);
	}

	.knob {
		position: absolute;
		top: 1.5px;
		left: 1.5px;
		width: 19px;
		height: 19px;
		border-radius: 50%;
		background: #fff;
		box-shadow: 0 1px 2px rgba(0, 0, 0, 0.25);
		transition: transform 0.15s ease;
	}

	.switch.on .knob {
		transform: translateX(16px);
	}

	/* ---- Notes folder path (middle-truncated) ---- */
	.path {
		font-size: 13px;
		color: var(--bv-text-muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		max-width: 260px;
	}

	/* ---- Hotkey value ---- */
	.hotkey {
		font-family:
			ui-monospace, 'SF Mono', Menlo, Monaco, 'Cascadia Code', monospace;
		font-size: 12px;
		color: var(--bv-text-muted);
	}

	/* ---- Footer ---- */
	.footer {
		flex-shrink: 0;
		display: flex;
		justify-content: flex-end;
		align-items: center;
		gap: 10px;
		padding: 16px;
		border-top: 1px solid var(--bv-border);
		background: var(--bv-bg);
	}
</style>

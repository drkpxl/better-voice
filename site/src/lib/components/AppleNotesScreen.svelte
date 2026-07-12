<script lang="ts">
	import AppWindow from './AppWindow.svelte';

	// Static, display-only recreation of Apple Notes showing what Better Voice creates
	// after a meeting: a summary note (and its matching transcript note) dropped into
	// the folder you picked during setup. No interactivity — realistic sample data only.

	interface NoteRow {
		title: string;
		preview: string;
		time: string;
		selected?: boolean;
	}

	const notes: NoteRow[] = [
		{
			title: 'Jun 18th - Q3 Roadmap Sync',
			preview: 'Priya, Sam, and Jordan reviewed the Q3 roadmap. The API migration is unblocked…',
			time: '9:03 AM',
			selected: true
		},
		{
			title: 'Jun 18th - Q3 Roadmap Sync (Transcript)',
			preview: 'Priya: I think we can ship the beta by Friday if the API work lands…',
			time: '9:02 AM'
		}
	];
</script>

<AppWindow title="Notes" theme="light">
	<div class="notes-app">
		<!-- LEFT SIDEBAR -->
		<aside class="sidebar">
			<div class="sidebar-header">
				<div class="search">
					<svg class="search-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
						<circle cx="11" cy="11" r="7" />
						<line x1="16.5" y1="16.5" x2="21" y2="21" />
					</svg>
					<span class="search-placeholder">Search</span>
				</div>
			</div>

			<div class="folder-row">
				<svg class="folder-icon" viewBox="0 0 24 24" fill="none" aria-hidden="true">
					<path
						d="M3 6.5a1.5 1.5 0 0 1 1.5-1.5h4.4a1.5 1.5 0 0 1 1.1.48L11.6 7H19.5A1.5 1.5 0 0 1 21 8.5v9A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5v-11Z"
						fill="#8bb4f7"
						stroke="#5a8fe0"
						stroke-width="0.75"
					/>
				</svg>
				<span class="folder-name">Meetings</span>
				<span class="folder-count">2</span>
			</div>

			<ul class="list">
				{#each notes as n, i (i)}
					<li class="row" class:selected={n.selected}>
						<span class="row-title">{n.title}</span>
						<span class="row-meta">
							<span class="row-time">{n.time}</span>
							<span class="row-preview">{n.preview}</span>
						</span>
					</li>
				{/each}
			</ul>
		</aside>

		<!-- RIGHT NOTE DETAIL -->
		<section class="detail">
			<div class="note-toolbar">
				<span class="note-folder-crumb">
					<svg viewBox="0 0 24 24" fill="none" aria-hidden="true" width="13" height="13">
						<path
							d="M3 6.5a1.5 1.5 0 0 1 1.5-1.5h4.4a1.5 1.5 0 0 1 1.1.48L11.6 7H19.5A1.5 1.5 0 0 1 21 8.5v9A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5v-11Z"
							fill="#8bb4f7"
							stroke="#5a8fe0"
							stroke-width="0.75"
						/>
					</svg>
					Meetings
				</span>
				<span class="spacer"></span>
				<button class="btn" type="button">Share</button>
			</div>

			<div class="note-body">
				<h1 class="note-title">Jun 18th - Q3 Roadmap Sync</h1>
				<p class="note-timestamp">Thursday, June 18, 2026 at 9:03 AM · 27 min</p>

				<p class="note-p">
					Priya, Sam, and Jordan reviewed the Q3 roadmap. The API migration is unblocked
					now that the auth refactor landed, and the team agreed to ship the beta by
					Friday.
				</p>

				<p class="note-heading">Key points</p>
				<ul class="note-bullets">
					<li>Auth refactor is done — Priya's API migration is unblocked</li>
					<li>Beta ships Friday</li>
					<li>Error-rate dashboard needs a look before launch</li>
				</ul>

				<p class="note-heading">Action items</p>
				<ul class="note-checklist">
					<li><span class="checkbox" aria-hidden="true"></span> Sam — send the updated spec</li>
					<li><span class="checkbox" aria-hidden="true"></span> Priya — review the error-rate dashboard</li>
				</ul>
			</div>
		</section>
	</div>
</AppWindow>

<style>
	.notes-app {
		display: flex;
		flex: 1;
		min-height: 0;
		height: 560px;
		max-height: 560px;
		overflow: hidden;
	}

	/* ---------- Sidebar ---------- */
	.sidebar {
		display: flex;
		flex-direction: column;
		flex: 0 0 260px;
		min-width: 220px;
		background: var(--bv-sidebar);
		border-right: 1px solid var(--bv-border);
		min-height: 0;
	}

	.sidebar-header {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 8px;
		flex-shrink: 0;
	}

	.search {
		display: flex;
		align-items: center;
		gap: 5px;
		flex: 1;
		min-width: 0;
		height: 24px;
		padding: 0 7px;
		background: var(--bv-field);
		border: 1px solid var(--bv-border);
		border-radius: 5px;
	}

	.search-icon {
		width: 13px;
		height: 13px;
		flex-shrink: 0;
		color: var(--bv-text-muted);
	}

	.search-placeholder {
		font-size: 12px;
		color: var(--bv-text-muted);
	}

	.folder-row {
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 6px 12px 8px;
		flex-shrink: 0;
	}

	.folder-icon {
		width: 15px;
		height: 15px;
		flex-shrink: 0;
	}

	.folder-name {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--bv-text);
	}

	.folder-count {
		font-size: 11px;
		color: var(--bv-text-muted);
	}

	/* ---------- Note list ---------- */
	.list {
		list-style: none;
		margin: 0;
		padding: 0 8px 8px;
		overflow-y: auto;
		flex: 1;
		min-height: 0;
	}

	.row {
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding: 8px 10px;
		border-radius: 6px;
		margin-bottom: 1px;
	}

	.row.selected {
		background: #ffd426;
	}

	.row-title {
		font-size: 13px;
		font-weight: 600;
		color: var(--bv-text);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.row-meta {
		display: flex;
		align-items: baseline;
		gap: 6px;
		min-width: 0;
	}

	.row-time {
		font-size: 11px;
		color: var(--bv-text-muted);
		flex-shrink: 0;
	}

	.row-preview {
		font-size: 11px;
		color: var(--bv-text-muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.row.selected .row-title,
	.row.selected .row-time,
	.row.selected .row-preview {
		color: #423b00;
	}

	/* ---------- Detail pane ---------- */
	.detail {
		display: flex;
		flex-direction: column;
		flex: 1;
		min-width: 0;
		min-height: 0;
		background: #ffffff;
	}

	.note-toolbar {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 8px 16px;
		border-bottom: 1px solid var(--bv-border);
		flex-shrink: 0;
	}

	.note-folder-crumb {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		font-size: 12px;
		color: var(--bv-text-muted);
	}

	.spacer {
		flex: 1;
	}

	.btn {
		font-family: inherit;
		font-size: 12px;
		color: var(--bv-text);
		padding: 3px 11px;
		border: 1px solid var(--bv-border-strong);
		border-radius: 6px;
		background: var(--bv-field);
		cursor: default;
		white-space: nowrap;
	}

	.note-body {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		padding: 22px 28px 28px;
	}

	.note-title {
		font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', sans-serif;
		font-size: 22px;
		font-weight: 700;
		color: #1d1d1f;
		margin: 0 0 2px;
		line-height: 1.25;
	}

	.note-timestamp {
		font-size: 12px;
		color: #86868b;
		margin: 0 0 16px;
	}

	.note-p {
		font-size: 14px;
		line-height: 1.6;
		color: #1d1d1f;
		margin: 0 0 16px;
		max-width: none;
	}

	.note-heading {
		font-size: 14px;
		font-weight: 700;
		color: #1d1d1f;
		margin: 0 0 6px;
	}

	.note-bullets {
		margin: 0 0 16px;
		padding-left: 20px;
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.note-bullets li {
		font-size: 14px;
		line-height: 1.5;
		color: #1d1d1f;
	}

	.note-checklist {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.note-checklist li {
		display: flex;
		align-items: flex-start;
		gap: 8px;
		font-size: 14px;
		line-height: 1.5;
		color: #1d1d1f;
	}

	.checkbox {
		display: inline-block;
		width: 14px;
		height: 14px;
		margin-top: 2px;
		flex-shrink: 0;
		border: 1.5px solid #b8b8bd;
		border-radius: 4px;
	}

	/* ---------- Narrow degrade ---------- */
	@media (max-width: 560px) {
		.sidebar {
			flex-basis: 190px;
			min-width: 170px;
		}
		.row-preview {
			display: none;
		}
		.note-body {
			padding: 18px 18px 24px;
		}
	}
</style>

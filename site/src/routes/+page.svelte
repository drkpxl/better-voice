<script lang="ts">
	import { base } from "$app/paths";
	import AppleNotesScreen from "$lib/components/AppleNotesScreen.svelte";
	import ImportWizardScreen from "$lib/components/ImportWizardScreen.svelte";
	import SettingsScreen from "$lib/components/SettingsScreen.svelte";
	import MenuBarScene from "$lib/components/MenuBarScene.svelte";

	const version = "1.1.1";
	const minMacOS = "15 Sequoia";
	// Stable alias maintained by client/scripts/release.sh (copies the newest DMG over it).
	const releaseUrl = `${base}/downloads/BetterVoice2-latest.dmg`;
	// Flip to true once release.sh has published the DMG (until then the download would 404,
	// so the CTAs show a "coming soon" state instead of a dead link).
	const available = true;
	// Canonical/OG absolute base (custom domain).
	const siteUrl = "https://voice.baselinemakes.com/";

	const shots = [
		{
			id: "notes",
			label: "In Apple Notes",
			caption:
				"Every meeting shows up as a titled note in Apple Notes, ready to search, edit, and share.",
		},
		{
			id: "import",
			label: "Record or import",
			caption:
				"Start a recording from the menu bar, or drop in a file you already have. Better Voice transcribes it, has you name the speakers, and adds the summary to Apple Notes.",
		},
		{
			id: "dictation",
			label: "Dictation",
			caption:
				"Hold your hotkey anywhere. The menu-bar app transcribes with Parakeet and types at your cursor.",
		},
		{
			id: "settings",
			label: "Settings",
			caption:
				"Choose your Apple Notes folders and, if you like, point summarization at a different model.",
		},
	];
	let active = $state("notes");

	// WAI-ARIA tabs: left/right arrows move between tabs and follow focus.
	function onTabKey(e: KeyboardEvent) {
		if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
		e.preventDefault();
		const n = shots.length;
		const i = shots.findIndex((s) => s.id === active);
		const next = e.key === "ArrowRight" ? (i + 1) % n : (i - 1 + n) % n;
		active = shots[next].id;
		document.getElementById(`tab-${active}`)?.focus();
	}

	// The two jobs every other setup splits across two products. This is the page's spine: the
	// argument is not "cheaper" or "more accurate", it is "one app, and the output lands somewhere
	// you already are".
	const jobs = [
		{
			kicker: "Job one",
			title: "Dictation, in every app you use",
			body: "Hold your hotkey, talk, let go. The text appears at your cursor: email, Slack, your editor, a form in the browser. There's no window to switch to and nothing to paste. Filler words come out by a fixed word list and your own spellings go in by exact word-match, so nothing rewrites what you actually said.",
			replaces: "Instead of a dictation subscription",
		},
		{
			kicker: "Job two",
			title: "Meeting notes, written and filed",
			body: "Record the call straight off your Mac, drop in a recording you already have, or paste a transcript. Better Voice transcribes it, works out who spoke when, has you name the voices once, and writes a summary with a real title. Name someone once and it recognises them in later meetings.",
			replaces: "Instead of an AI notetaker",
		},
	];

	// Setup, told plainly. Both asks are real, and burying either one just moves the surprise to
	// first launch — where it stops being an informed choice and becomes a support problem.
	const setup = [
		{
			note: "Required · automatic · once",
			title: "A one-time 470 MB download",
			body: "On first launch Better Voice downloads NVIDIA's Parakeet speech model: about 470 MB, a few minutes, once. That download is exactly why your audio never has to leave your Mac afterwards. The menu bar shows progress, and dictation switches on the moment it lands.",
		},
		{
			note: "Optional · Ollama for long meetings",
			title: "Summaries need a model. You choose which.",
			body: "Transcription needs no setup at all. Writing the summary does need a language model. Apple's on-device one is zero setup but has a short context window, so a long meeting gets chunked. For hour-long calls, point Better Voice at Ollama or any OpenAI-compatible server you run. Either way it stays on your machine.",
		},
	];

	const features = [
		{
			title: "It lands in Apple Notes",
			body: "Not a library inside another app you have to remember to open. Every meeting becomes a titled note with summary and transcript, in folders you pick once. Searchable in Spotlight, editable on your phone, and already synced to your iPad by the time you shut your laptop.",
		},
		{
			title: "Works on a plane",
			body: "Once the speech model is down, dictation and transcription need no connection at all. They're running on your Mac, not on someone's API. Only the Apple Notes sync at the end wants the internet, and it waits.",
		},
		{
			title: "No bot joins your call",
			body: "Better Voice records the audio on your machine instead of attending as a guest. Nobody else in the meeting has to accept a third-party notetaker, and there's no participant list entry explaining what you're using.",
		},
		{
			title: "Learns the people you meet with",
			body: "Name a voice once and Better Voice suggests that name next time it hears them. Naming gets faster every meeting instead of starting over.",
		},
		{
			title: "Free, and MIT-licensed",
			body: "No subscription, no account, and no tier that holds back the useful half. The source is on GitHub.",
		},
		{
			title: "Installs and updates cleanly",
			body: "Signed with a Developer ID and notarized by Apple, so it installs by drag-and-drop with no Gatekeeper workaround. Updates arrive in-app, and your permissions carry across them.",
		},
	];
</script>

<svelte:head>
	<title
		>Better Voice: dictation and AI meeting notes in one Mac app, saved to Apple Notes</title
	>
	<meta
		name="description"
		content="Dictation and AI meeting notes are normally two separate subscriptions. Better Voice is one free Mac app that does both. Hold a key to dictate into any app, record or import a meeting and get a speaker-labeled summary. It files everything in Apple Notes. Runs entirely on your Mac. Your audio never leaves it."
	/>
	<link rel="canonical" href={siteUrl} />

	<!-- Open Graph / Twitter (link previews). Absolute URLs — update if the site moves to a
	     custom domain like bettervoice.baselinemakes.com. -->
	<meta property="og:type" content="website" />
	<meta property="og:site_name" content="Better Voice" />
	<meta
		property="og:title"
		content="Better Voice: dictation and AI meeting notes in one Mac app, saved to Apple Notes"
	/>
	<meta
		property="og:description"
		content="Dictation and AI meeting notes are normally two apps. Better Voice is one. Dictate anywhere with a hotkey, record or import a meeting, get a speaker-labeled summary in Apple Notes. On-device, free, no subscription."
	/>
	<meta property="og:url" content={siteUrl} />
	<meta property="og:image" content={`${siteUrl}og.png`} />
	<meta property="og:image:width" content="1200" />
	<meta property="og:image:height" content="630" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta
		name="twitter:title"
		content="Better Voice: dictation and AI meeting notes in one Mac app, saved to Apple Notes"
	/>
	<meta
		name="twitter:description"
		content="Dictation and AI meeting notes are normally two apps. Better Voice is one. Dictate anywhere with a hotkey, record or import a meeting, get a speaker-labeled summary in Apple Notes. On-device, free, no subscription."
	/>
	<meta name="twitter:image" content={`${siteUrl}og.png`} />
</svelte:head>

<div class="container bv-page">
	<!-- Hero -->
	<section class="hero">
		<div class="hero-icon">
			<img
				src="{base}/icon.png"
				alt="Better Voice app icon"
				width="160"
				height="160"
			/>
		</div>
		<div class="hero-content">
			<p class="eyebrow">Free · On-device · macOS</p>
			<h1>
				Everyone else sells you two apps. <span class="acc">This is one.</span>
			</h1>
			<p class="lead">
				Dictation lives in one subscription. Meeting notes live in another. Better
				Voice does both jobs in a single Mac app. Hold a key to dictate anywhere,
				record a meeting and get a speaker-labeled summary. Then it files the result
				in Apple Notes, where you already keep everything. It all runs on your Mac,
				so your audio never leaves it.
			</p>
			<div class="hero-cta">
				{#if available}
					<a
						class="btn-primary"
						href={releaseUrl}
						target="_blank"
						rel="noopener noreferrer"
					>
						<svg
							xmlns="http://www.w3.org/2000/svg"
							width="20"
							height="20"
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="2"
							stroke-linecap="round"
							stroke-linejoin="round"
							aria-hidden="true"
						>
							<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
							<polyline points="7 10 12 15 17 10" />
							<line x1="12" y1="15" x2="12" y2="3" />
						</svg>
						Download for macOS
					</a>
					<span class="hero-meta"
						>Notarized · macOS {minMacOS} or later · Apple silicon</span
					>
				{:else}
					<span class="btn-primary btn-soon" aria-disabled="true"
						>Coming soon</span
					>
					<span class="hero-meta"
						>v{version} in final testing · macOS {minMacOS} or later · Apple silicon</span
					>
				{/if}
			</div>
			<p class="hero-note readability-limit">
				Free and MIT-licensed. One first-run download puts the speech model on your
				Mac. <a href="#setup">Here's what setup actually involves</a>.
			</p>
		</div>
	</section>

	<!-- The spine of the page: the two jobs a normal setup splits across two products, and the
	     one place their output lands. -->
	<section class="jobs" id="jobs">
		<h2>Two jobs. One app. One place they land.</h2>
		<p class="jobs-intro">
			These are normally two separate purchases from two separate companies, each with its own
			app to open, its own bill, and its own silo your words end up in. Better Voice does both,
			and hands the result to Apple Notes.
		</p>
		<div class="jobs-grid">
			{#each jobs as j (j.title)}
				<article class="job-card">
					<p class="job-kicker">{j.kicker}</p>
					<h3>{j.title}</h3>
					<p class="job-body">{j.body}</p>
					<p class="job-replaces">{j.replaces}</p>
				</article>
			{/each}
		</div>
	</section>

	<!-- Showcase: live HTML/CSS recreations of the actual app UI -->
	<section class="showcase" aria-label="Better Voice screens">
		<div class="tabs" role="tablist" aria-label="Choose a screen">
			{#each shots as shot (shot.id)}
				<button
					type="button"
					role="tab"
					id={`tab-${shot.id}`}
					class="tab"
					class:is-active={active === shot.id}
					aria-selected={active === shot.id}
					aria-controls="bv-stage"
					tabindex={active === shot.id ? 0 : -1}
					onclick={() => (active = shot.id)}
					onkeydown={onTabKey}
				>
					{shot.label}
				</button>
			{/each}
		</div>

		<div
			class="stage"
			id="bv-stage"
			role="tabpanel"
			aria-labelledby={`tab-${active}`}
		>
			{#if active === "notes"}
				<AppleNotesScreen />
			{:else if active === "import"}
				<ImportWizardScreen step="speakers" />
			{:else if active === "dictation"}
				<MenuBarScene />
			{:else if active === "settings"}
				<SettingsScreen />
			{/if}
		</div>

		<p class="stage-caption">
			{shots.find((s) => s.id === active)?.caption}
		</p>
	</section>

	<!-- Compare: the side-by-side that makes the one-app claim concrete. -->
	<section class="compare">
		<h2>What you’d otherwise be running</h2>
		<p class="compare-intro readability-limit">
			Two products, two bills, and your words split across both of them, plus
			whichever cloud each vendor keeps your recordings in.
		</p>
		<div class="compare-grid">
			<div class="compare-col compare-before">
				<h3>The usual setup</h3>
				<ul>
					<li>A dictation app, on subscription</li>
					<li>An AI notetaker like Granola or Otter, on another subscription</li>
					<li>A bot that joins the call to record it</li>
					<li>Your meetings on their servers, in their app</li>
					<li>Two places to look for something you said</li>
				</ul>
			</div>
			<div class="compare-col compare-after">
				<h3>With Better Voice</h3>
				<ul>
					<li>Hold-to-talk dictation in every app</li>
					<li>Records and summarizes meetings in the same app</li>
					<li>No bot; the audio is captured on your Mac</li>
					<li>Notes in Apple Notes, on every device you own</li>
					<li>Free, MIT-licensed, and nothing leaves your Mac</li>
				</ul>
			</div>
		</div>
	</section>


	<!-- Features -->
	<section class="features" id="features">
		<h2>What you get</h2>
		<div class="feature-grid">
			{#each features as f (f.title)}
				<article class="feature-card">
					<h3>{f.title}</h3>
					<p>{f.body}</p>
				</article>
			{/each}
		</div>
	</section>

	<!-- Setup: the two real asks, stated plainly. Hiding either only moves the surprise to first
	     launch, where it stops being an informed choice and becomes a support problem. -->
	<section class="setup" id="setup">
		<h2>What setup actually involves</h2>
		<p class="setup-intro readability-limit">
			Two things are worth knowing before you download. Both are real, and neither is buried in
			a settings pane.
		</p>
		<div class="setup-grid">
			{#each setup as s (s.title)}
				<article class="setup-card">
					<p class="setup-note">{s.note}</p>
					<h3>{s.title}</h3>
					<p>{s.body}</p>
				</article>
			{/each}
		</div>
	</section>

	<!-- Privacy callout -->
	<section class="privacy">
		<div class="privacy-card">
			<h2>Your audio never leaves your Mac</h2>
			<p class="readability-limit">
				AI notetakers upload your meetings to their servers to transcribe and
				summarize them. Better Voice does all of that on your Mac. The only
				thing that ever leaves is the finished note and only to <em
					>your own</em
				> iCloud, the same way every other Apple Note syncs. We run no servers.
			</p>
		</div>
	</section>

	<!-- Download -->
	<section class="download" id="download">
		<h2>Download</h2>
		<div class="download-card">
			<div class="download-card-main">
				<p class="download-version">Better Voice {version}</p>
				<p class="download-req">
					Requires macOS {minMacOS} or later · Apple silicon
				</p>
				{#if available}
					<a
						class="btn-primary"
						href={releaseUrl}
						target="_blank"
						rel="noopener noreferrer"
					>
						Download <code>.dmg</code>
					</a>
				{:else}
					<span class="btn-primary btn-soon" aria-disabled="true"
						>Coming soon</span
					>
					<p class="download-note">
Better Voice 1.0 is in final testing. The download lands here
					shortly.
					</p>
				{/if}
			</div>
			<div class="download-card-aside">
				<h3>How to install</h3>
				<ol class="install-steps">
					<li>
						<strong>Open the disk image</strong> and drag
						<code>BetterVoice2.app</code>
						into your Applications folder.
					</li>

					<li>
						<strong>Grant permissions when asked</strong>: Microphone, Input Monitoring
						(for the hotkey), Accessibility (to type at your cursor), and Automation
						for Notes (so Better Voice can add meeting notes and open them for you).
						Then quit and reopen once so macOS applies them.
					</li>
					<li>
						<strong>Pick your Apple Notes folders</strong> this is where your notes
						and transcripts will be stored.
					</li>
				</ol>
			</div>
		</div>
	</section>
</div>

<style>
	.bv-page {
		padding-bottom: var(--space-2xl);
	}

	/* Hero */
	.hero {
		display: flex;
		flex-direction: column;
		gap: var(--space-lg);
		padding-block: var(--space-xl) var(--space-lg);
		align-items: flex-start;
	}

	@media (min-width: 768px) {
		.hero {
			flex-direction: row;
			align-items: center;
			gap: var(--space-xl);
			padding-block: var(--space-2xl) var(--space-lg);
		}
	}

	.hero-icon img {
		width: 104px;
		height: 104px;
		border-radius: 22px;
		box-shadow: 0 18px 44px -18px rgba(88, 71, 214, 0.55);
	}

	@media (min-width: 768px) {
		.hero-icon img {
			width: 160px;
			height: 160px;
		}
	}

	.hero-content {
		flex: 1;
	}

	.eyebrow {
		font-family: var(--font-mono);
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.12em;
		color: var(--color-accent);
		margin-bottom: var(--space-md);
	}

	.hero h1 {
		margin-bottom: var(--space-md);
	}

	.hero h1 .acc {
		color: var(--color-accent);
	}

	.lead {
		font-size: clamp(1.0625rem, 2vw, 1.25rem);
		color: var(--color-text-muted);
		line-height: 1.6;
		margin-bottom: var(--space-lg);
	}

	.hero-cta {
		display: flex;
		flex-direction: column;
		gap: var(--space-sm);
		align-items: flex-start;
	}

	@media (min-width: 480px) {
		.hero-cta {
			flex-direction: row;
			align-items: center;
			gap: var(--space-md);
			flex-wrap: wrap;
		}
	}

	.hero-meta {
		font-family: var(--font-mono);
		font-size: 0.8125rem;
		color: var(--color-text-muted);
	}

	.hero-note {
		margin-top: var(--space-md);
		font-size: 0.9375rem;
		line-height: 1.6;
		color: var(--color-text-muted);
		max-width: 58ch;
	}

	/* Primary button */
	.btn-primary {
		display: inline-flex;
		align-items: center;
		gap: var(--space-sm);
		padding: 0.875rem 1.5rem;
		font-family: var(--font-mono);
		font-weight: 500;
		font-size: 0.9375rem;
		color: var(--color-on-accent);
		background-color: var(--color-accent);
		border-radius: var(--border-radius);
		text-decoration: none;
		transition:
			background-color var(--transition-fast),
			transform var(--transition-fast),
			box-shadow var(--transition-base);
		box-shadow: 0 6px 20px -10px rgba(88, 71, 214, 0.6);
	}

	.btn-primary:hover {
		background-color: var(--color-accent-hover);
		color: var(--color-on-accent);
		transform: translateY(-1px);
		box-shadow: 0 10px 26px -12px rgba(88, 71, 214, 0.7);
	}

	.btn-primary code {
		background: color-mix(in srgb, var(--color-on-accent) 16%, transparent);
		padding: 0.05rem 0.4rem;
		border-radius: 4px;
		font-size: 0.85em;
	}

	/* Pre-launch "coming soon" state — looks like the primary button but isn't a link. */
	.btn-soon {
		background-color: var(--color-text-muted);
		box-shadow: none;
		cursor: default;
	}

	.btn-soon:hover {
		background-color: var(--color-text-muted);
		transform: none;
		box-shadow: none;
	}
	/* Section spacing */
	.showcase {
		padding-block: var(--space-2xl);
		border-block: 1px solid var(--color-border-light);
	}

	.jobs,
	.compare,
	.features,
	.setup,
	.privacy,
	.download {
		padding-block: var(--space-2xl);
	}

	.tabs {
		display: flex;
		flex-wrap: wrap;
		gap: var(--space-sm);
		margin-bottom: var(--space-lg);
	}

	.tab {
		font-family: var(--font-mono);
		font-size: 0.8125rem;
		font-weight: 500;
		padding: 0.5rem 0.95rem;
		border-radius: 999px;
		border: 1px solid var(--color-border);
		background-color: var(--color-bg-card);
		color: var(--color-text-muted);
		cursor: pointer;
		transition:
			background-color var(--transition-fast),
			border-color var(--transition-fast),
			color var(--transition-fast);
	}

	.tab:hover {
		border-color: var(--color-accent);
		color: var(--color-text);
	}

	.tab.is-active {
		background-color: var(--color-accent);
		border-color: var(--color-accent);
		color: var(--color-on-accent);
	}

	.stage {
		max-width: 960px;
		margin-inline: auto;
	}

	.stage-caption {
		font-size: 0.9375rem;
		color: var(--color-text-muted);
		line-height: 1.6;
		text-align: center;
		max-width: 60ch;
		margin: var(--space-lg) auto 0;
	}

	/* Section spacing */
	.showcase,
	.jobs,
	.compare,
	.features,
	.setup,
	.privacy,
	.download {
		padding-block: var(--space-xl);
	}

	.jobs h2,
	.compare h2,
	.features h2,
	.setup h2,
	.download h2 {
		margin-bottom: var(--space-lg);
	}

	/* Anchored sections sit under the sticky header, so give the jump targets clearance. */
	.jobs,
	.compare,
	.features,
	.setup,
	.download {
		scroll-margin-top: 5rem;
	}

	/* Jobs — the two halves of the pitch, side by side so "one app, two jobs" is legible
	   at a glance rather than asserted in prose. */
	.jobs h2 {
		margin-bottom: var(--space-lg);
		max-width: 24ch;
	}

	.jobs-intro {
		color: var(--color-text-muted);
		line-height: 1.7;
		max-width: 70ch;
		margin-bottom: var(--space-lg);
	}

	/* Exactly two cards: one column on phones, two side by side from tablet up. */
	.jobs-grid {
		display: grid;
		grid-template-columns: 1fr;
		gap: var(--space-lg);
	}

	@media (min-width: 768px) {
		.jobs-grid {
			grid-template-columns: 1fr 1fr;
		}
	}

	.job-card {
		background-color: var(--color-bg-card);
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		padding: var(--space-lg);
		display: flex;
		flex-direction: column;
	}

	.job-kicker {
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.08em;
		color: var(--color-accent);
		margin-bottom: var(--space-sm);
	}

	.job-card h3 {
		font-size: 1.25rem;
		margin-bottom: var(--space-sm);
	}

	.job-body {
		color: var(--color-text-muted);
		line-height: 1.7;
		margin: 0;
	}

	/* Pushed to the card's foot so both cards' "instead of" lines sit on one baseline
	   regardless of body length. */
	.job-replaces {
		margin-top: auto;
		padding-top: var(--space-md);
		font-size: 0.8125rem;
		font-weight: 500;
		color: var(--color-accent);
		font-family: var(--font-mono);
	}

	/* Setup — the two real asks. Styled as plainly as the copy reads: no badges, no
	   warning colors, because neither of these is a problem to be softened. */
	.setup-intro {
		color: var(--color-text-muted);
		line-height: 1.7;
		max-width: 70ch;
		margin-bottom: var(--space-lg);
	}

	.setup-grid {
		display: grid;
		grid-template-columns: 1fr;
		gap: var(--space-lg);
	}

	@media (min-width: 768px) {
		.setup-grid {
			grid-template-columns: 1fr 1fr;
		}
	}

	.setup-card {
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		padding: var(--space-lg);
	}

	.setup-note {
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.08em;
		color: var(--color-text-muted);
		margin-bottom: var(--space-sm);
	}

	.setup-card h3 {
		font-size: 1.125rem;
		margin-bottom: var(--space-sm);
	}

	.setup-card p:last-child {
		color: var(--color-text-muted);
		line-height: 1.7;
		margin: 0;
	}

	/* Compare: before/after */
	.compare-intro {
		color: var(--color-text-muted);
		line-height: 1.7;
		max-width: 70ch;
		margin-bottom: var(--space-lg);
	}

	.compare-grid {
		display: grid;
		grid-template-columns: 1fr;
		gap: var(--space-lg);
	}

	@media (min-width: 768px) {
		.compare-grid {
			grid-template-columns: 1fr 1fr;
			gap: var(--space-xl);
		}
	}

	.compare-col {
		background-color: var(--color-bg-card);
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		padding: var(--space-lg);
	}

	.compare-col h3 {
		font-family: var(--font-mono);
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.12em;
		margin-bottom: var(--space-md);
	}

	.compare-before h3 {
		color: var(--color-text-muted);
	}

	.compare-after {
		border-left: 4px solid var(--color-accent);
	}

	.compare-after h3 {
		color: var(--color-accent);
	}

	.compare-col ul {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--space-sm);
	}

	.compare-col li {
		line-height: 1.5;
		font-size: 0.9375rem;
	}

	.compare-before li {
		color: var(--color-text-muted);
		text-decoration: line-through;
		text-decoration-color: var(--color-border);
		text-decoration-thickness: 1px;
	}

	.compare-after li {
		color: var(--color-text);
		font-weight: 500;
	}

	.compare-after li::before {
		content: "✓ ";
		color: var(--color-accent);
		font-weight: 700;
	}

	/* Feature cards */
	.feature-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(min(100%, 280px), 1fr));
		gap: var(--space-lg);
	}

	.feature-card {
		background-color: var(--color-bg-card);
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		padding: var(--space-lg);
	}

	.feature-card h3 {
		font-size: 1.125rem;
		margin-bottom: var(--space-sm);
	}

	.feature-card p {
		color: var(--color-text-muted);
		font-size: 0.9375rem;
		line-height: 1.6;
		margin: 0;
	}

	/* Privacy callout */
	.privacy-card {
		background-color: var(--color-bg-card);
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		padding: var(--space-lg);
		border-left: 4px solid var(--color-accent);
	}

	.privacy-card h2 {
		margin-bottom: var(--space-md);
	}

	.privacy-card p {
		color: var(--color-text-muted);
		line-height: 1.7;
		margin: 0;
	}

	/* Download */
	.download-card {
		background-color: var(--color-bg-card);
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		padding: var(--space-lg);
		display: grid;
		grid-template-columns: 1fr;
		gap: var(--space-lg);
	}

	@media (min-width: 768px) {
		.download-card {
			grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr);
			gap: var(--space-xl);
			padding: var(--space-lg);
		}
	}

	.download-card-main {
		display: flex;
		flex-direction: column;
		gap: var(--space-sm);
		align-items: flex-start;
	}

	.download-version {
		font-family: var(--font-display);
		font-size: 1.25rem;
		font-weight: var(--weight-bold);
		color: var(--color-text);
		margin: 0;
	}

	.download-req {
		font-family: var(--font-mono);
		font-size: 0.8125rem;
		color: var(--color-text-muted);
		margin: 0 0 var(--space-md);
	}

	.download-card-aside h3 {
		font-size: 1rem;
		margin-bottom: var(--space-sm);
	}

	.download-card-aside li {
		color: var(--color-text-muted);
		font-size: 0.9375rem;
		line-height: 1.7;
	}

	.download-card-aside li strong {
		color: var(--color-text);
	}

	.install-steps {
		margin: var(--space-md) 0;
		padding-left: 1.25rem;
		display: flex;
		flex-direction: column;
		gap: var(--space-md);
	}

	.install-steps li::marker {
		color: var(--color-accent);
		font-weight: var(--weight-bold);
	}

	.download-card-aside code {
		font-family: var(--font-mono);
		font-size: 0.85em;
		background-color: var(--color-bg-alt);
		padding: 0.05rem 0.35rem;
		border-radius: 4px;
	}

	.download-note {
		font-size: 0.8125rem;
		font-style: italic;
		margin-top: var(--space-md);
	}
</style>

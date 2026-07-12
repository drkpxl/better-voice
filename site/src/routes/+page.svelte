<script lang="ts">
	import { base } from "$app/paths";
	import AppleNotesScreen from "$lib/components/AppleNotesScreen.svelte";
	import ImportWizardScreen from "$lib/components/ImportWizardScreen.svelte";
	import SettingsScreen from "$lib/components/SettingsScreen.svelte";
	import MenuBarScene from "$lib/components/MenuBarScene.svelte";

	const version = "1.0.0";
	const minMacOS = "26 Tahoe";
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
				"Start a recording from the menu bar, or drop in a file you already have — Better Voice transcribes it, has you name the speakers, and adds the summary to Apple Notes.",
		},
		{
			id: "dictation",
			label: "Dictation",
			caption:
				"Hold your hotkey anywhere. The menu-bar app listens, cleans up, and types at your cursor.",
		},
		{
			id: "settings",
			label: "Settings",
			caption:
				"Choose your Apple Notes folders and, if you like, point dictation and summaries at a different model.",
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

	const features = [
		{
			title: "Dictation in any app",
			body: "Hold your hotkey, speak, and release. The text is cleaned up and inserted at your cursor in whatever app you’re in. Local private AI fixes recognition errors and drops filler words.",
		},
		{
			title: "Meetings become Apple Notes",
			body: "Three ways to capture a meeting: start a recording from the menu bar and Better Voice records the call straight off your Mac, no bot to invite or drop in a recording you already have or paste a transcript. All three end the same way: transcribed, speakers named, summarized, and added straight to Apple Notes, transcript included.",
		},
		{
			title: "Bring your own model",
			body: "Dictation cleanup and meeting summaries are configured independently. Each can use Apple on-device (zero setup) or a local model server you run yourself, for people who want more control or more accuracy.",
		},
		{
			title: "Private by default",
			body: "Transcription and speaker recognition happen entirely on your Mac. Your audio never leaves the machine and the notes it produces sync the same way any other Apple Note does, through your own iCloud account.",
		},
		{
			title: "Learns your speakers",
			body: "Name a voice once and Better Voice remembers it, later meetings suggest the same name automatically, so naming gets faster over time.",
		},
		{
			title: "Updates in-app",
			body: "Signed with a Developer ID and notarized by Apple, so it installs by drag-and-drop. New versions arrive in-app via Sparkle, and your permissions carry across updates.",
		},
	];
</script>

<svelte:head>
	<title
		>Better Voice — dictation & AI meeting notes for macOS, saved to Apple Notes</title
	>
	<meta
		name="description"
		content="Better Voice is one local Mac app that replaces a dictation subscription and an AI meeting notetaker. Dictate into any app with a hotkey. Record a meeting — or drop in a recording — and get a speaker-labeled summary delivered to Apple Notes. On-device, private, no subscription."
	/>
	<link rel="canonical" href={siteUrl} />

	<!-- Open Graph / Twitter (link previews). Absolute URLs — update if the site moves to a
	     custom domain like bettervoice.baselinemakes.com. -->
	<meta property="og:type" content="website" />
	<meta property="og:site_name" content="Better Voice" />
	<meta
		property="og:title"
		content="Better Voice — dictation & AI meeting notes for macOS, saved to Apple Notes"
	/>
	<meta
		property="og:description"
		content="One local Mac app that replaces a dictation subscription and an AI meeting notetaker. Dictate anywhere; record or import a meeting; get a speaker-labeled summary in Apple Notes. On-device and free — no subscription."
	/>
	<meta property="og:url" content={siteUrl} />
	<meta property="og:image" content={`${siteUrl}og.png`} />
	<meta property="og:image:width" content="1200" />
	<meta property="og:image:height" content="630" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta
		name="twitter:title"
		content="Better Voice — dictation & AI meeting notes for macOS, saved to Apple Notes"
	/>
	<meta
		name="twitter:description"
		content="One local Mac app that replaces a dictation subscription and an AI meeting notetaker. Dictate anywhere; record or import a meeting; get a speaker-labeled summary in Apple Notes. On-device and free — no subscription."
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
				Talk, and Better Voice types. Record, and it’s <span class="acc"
					>in Apple Notes.</span
				>
			</h1>
			<p class="lead">
				Better Voice replaces your dictation app and your AI meeting notetaker
				with one app that runs entirely on your Mac. Hold a single key to
				dictate into anything. Record a meeting or drop in a recording and get a
				clean, speaker-labeled summary delivered straight to Apple Notes, where
				it’s already waiting on your iPhone, iPad, and Mac. No subscription.
				Your privacy intact.
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

	<!-- Compare: the honest pitch — one app instead of three subscriptions -->
	<section class="compare">
		<h2>One app instead of three subscriptions</h2>
		<p class="compare-intro">
			The usual setup: pay for a dictation app, pay for an AI notetaker, and
			keep your meetings in yet another company’s cloud. Better Voice does both
			jobs on your Mac and hands the results to the notes app you already use.
		</p>
		<div class="compare-grid">
			<div class="compare-col compare-before">
				<h3>The usual way</h3>
				<ul>
					<li>A dictation subscription</li>
					<li>An AI notetaker like Granola or Otter</li>
					<li>Your meetings in their app, on their servers</li>
					<li>A monthly bill for each</li>
				</ul>
			</div>
			<div class="compare-col compare-after">
				<h3>With Better Voice</h3>
				<ul>
					<li>Hold-to-talk dictation in every app</li>
					<li>Records and summarizes your meetings</li>
					<li>Everything in Apple Notes, on every device you own</li>
					<li>Free, and nothing leaves your Mac</li>
				</ul>
			</div>
		</div>
	</section>

	<!-- Why -->
	<section class="why">
		<h2>Two things, done locally</h2>
		<div class="why-grid">
			<div>
				<h3>Dictation</h3>
				<p>
					Press your hotkey and talk. Better Voice transcribes on-device, tidies
					the text, and drops it wherever your cursor is — email, chat, code,
					notes. No window to switch to, nothing uploaded.
				</p>
			</div>
			<div>
				<h3>Meeting notes</h3>
				<p>
					Start a recording from the menu bar, drop in a file, or paste a
					transcript — Better Voice transcribes it, figures out who said what,
					names the voices, and writes a clean summary. It lands in Apple Notes
					as a titled note, transcript included. No new app to check: your
					summary is a normal Apple Note already in your exisitng workflow. Mac native just like you are.
				</p>
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

	<!-- Privacy callout -->
	<section class="privacy">
		<div class="privacy-card">
			<h2>Your audio never leaves Apple</h2>
			<p>
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
						Better Voice 1.0 is in final testing — the download lands here
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
						<strong>Grant permissions when asked</strong> — Microphone, Input Monitoring
						(for the hotkey), Accessibility (to type at your cursor), and Automation
						for Notes (so Better Voice can add meeting notes and open them for you)
						— then quit and reopen once so macOS applies them.
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

	/* Primary button */
	.btn-primary {
		display: inline-flex;
		align-items: center;
		gap: var(--space-sm);
		padding: 0.875rem 1.5rem;
		font-family: var(--font-mono);
		font-weight: 500;
		font-size: 0.9375rem;
		color: #fff;
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
		color: #fff;
		transform: translateY(-1px);
		box-shadow: 0 10px 26px -12px rgba(88, 71, 214, 0.7);
	}

	.btn-primary code {
		background: rgba(255, 255, 255, 0.18);
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

	/* Showcase */
	.showcase {
		padding-block: var(--space-md) var(--space-2xl);
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
		color: #fff;
	}

	.stage {
		max-width: 960px;
		margin-inline: auto;
	}

	.stage-caption {
		font-family: var(--font-mono);
		font-size: 0.875rem;
		color: var(--color-text-muted);
		line-height: 1.6;
		text-align: center;
		max-width: 60ch;
		margin: var(--space-md) auto 0;
	}

	/* Section spacing */
	.compare,
	.why,
	.features,
	.privacy,
	.download {
		padding-block: var(--space-xl);
	}

	.compare h2,
	.why h2,
	.features h2,
	.download h2 {
		margin-bottom: var(--space-lg);
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

	/* Why grid */
	.why-grid {
		display: grid;
		grid-template-columns: 1fr;
		gap: var(--space-lg);
	}

	@media (min-width: 768px) {
		.why-grid {
			grid-template-columns: 1fr 1fr;
			gap: var(--space-xl);
		}
	}

	.why h3 {
		font-family: var(--font-mono);
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.12em;
		color: var(--color-accent);
		margin-bottom: var(--space-sm);
	}

	.why p {
		color: var(--color-text-muted);
		line-height: 1.7;
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
			padding: var(--space-xl);
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

	.download-card-aside p,
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

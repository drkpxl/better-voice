<script lang="ts">
	import { base } from "$app/paths";
	import AppleNotesScreen from "$lib/components/AppleNotesScreen.svelte";
	import ImportWizardScreen from "$lib/components/ImportWizardScreen.svelte";
	import SettingsScreen from "$lib/components/SettingsScreen.svelte";
	import MenuBarScene from "$lib/components/MenuBarScene.svelte";

	const version = "1.0.4";
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
				"Start a recording from the menu bar, or drop in a file you already have — Better Voice transcribes it, has you name the speakers, and adds the summary to Apple Notes.",
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

	// Bake-off numbers, measured 2026-07-30 on one 116-second dictation recording (197 words)
	// and one 57.5-minute four-speaker recording. Full methodology and findings:
	// 2026-07-30-asr-bakeoff-findings.md.
	const researchStats = [
		{
			value: "35",
			label: "pipelines measured",
			note: "Seven on-device speech engines × five cleanup options, every combination scored on the same audio.",
		},
		{
			value: "19.1",
			unit: "pts",
			label: "moved by the engine",
			note: "The spread in word error rate between the best and worst speech engine tested.",
		},
		{
			value: "1.0–3.6",
			unit: "pts",
			label: "moved by the cleanup model",
			note: "Swapping the cleanup LLM inside any one engine barely shifts accuracy at all.",
		},
		{
			value: "9 of 28",
			label: "cleanup runs changed nothing",
			note: "Identical text after normalization — the model had only re-punctuated it.",
		},
	];

	const trustNotes = [
		{
			lead: "One recording of each kind.",
			body: "116 seconds of dictation, 197 words, one speaker, one mic — plus one 57.5-minute meeting. Enough to see a 14-point gap. Not enough to rank two pipelines half a point apart. Directional, not definitive.",
		},
		{
			lead: "Deliberately hard audio.",
			body: "Unscripted, disfluent, jargon-heavy, and scored against a reference I hand-wrote of what I meant to say. That is why these absolute numbers look high: the same models score in the low single digits on clean read-aloud benchmarks. Different test, not a contradiction.",
		},
		{
			lead: "No other apps were tested.",
			body: "This compares speech engines inside my own pipeline. It says nothing about how any other dictation or meeting app performs.",
		},
		{
			lead: "Nothing here measures streaming latency.",
			body: "Time-to-first-word is what actually governs how dictation feels, and every timing above is batch processing of a finished file.",
		},
	];

	const features = [
		{
			title: "Dictation in any app",
			body: "Hold your hotkey, speak, and release. Parakeet TDT v3 transcribes on-device, filler words are removed deterministically, and your vocabulary's spellings are applied by exact word-boundary replacement — no model runs on your dictated text. The text lands at your cursor in under 300 ms.",
		},
		{
			title: "Meetings become Apple Notes",
			body: "Three ways to capture a meeting: start a recording from the menu bar and Better Voice records the call straight off your Mac, no bot to invite or drop in a recording you already have or paste a transcript. All three end the same way: transcribed, speakers named, summarized, and added straight to Apple Notes, transcript included.",
		},
		{
			title: "Bring your own model for summaries",
			body: "Meeting summarization can use Apple on-device (zero setup) or a local model server you run yourself — Ollama or any OpenAI-compatible endpoint. Dictation has no model choice: Parakeet is the only engine, and it needs no configuration.",
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
		{
			title: "Measured, then changed",
			body: "Before deciding what to build I benchmarked 35 on-device dictation pipelines on my own voice and published the result — including the part where the pipeline I was shipping landed near the bottom. The engine work that followed from it is what ships today.",
		},
	];
</script>

<svelte:head>
	<title
		>Better Voice — dictation & AI meeting notes for macOS, saved to Apple Notes</title
	>
	<meta
		name="description"
		content="Better Voice is one free local Mac app that replaces a dictation subscription and an AI meeting notetaker. Dictate into any app with a hotkey. Record a meeting — or drop in a recording — and get a speaker-labeled summary delivered to Apple Notes. On-device, private, no subscription — and backed by a published benchmark of 35 on-device speech pipelines."
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
		content="One local Mac app that replaces a dictation subscription and an AI meeting notetaker. Dictate anywhere; record or import a meeting; get a speaker-labeled summary in Apple Notes. On-device and free — no subscription. Built on a published benchmark of 35 on-device speech pipelines."
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
		content="One local Mac app that replaces a dictation subscription and an AI meeting notetaker. Dictate anywhere; record or import a meeting; get a speaker-labeled summary in Apple Notes. On-device and free — no subscription. Built on a published benchmark of 35 on-device speech pipelines."
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
				dictate into anything — Parakeet TDT v3 transcribes on-device in under
				300 ms. Record a meeting or drop in a recording and get a clean,
				speaker-labeled summary delivered straight to Apple Notes, where it’s
				already waiting on your iPhone, iPad, and Mac. No subscription.
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
			<p class="hero-note">
				Free, MIT-licensed, and used by about two people so far — one of them me. So
				instead of a testimonial, here’s
				<a href="#research">the benchmark I ran on 35 speech pipelines</a> to work out
				what this app should actually be doing.
			</p>
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

	<!-- Research: the honest credibility argument — measurements, not popularity.
	     The bake-off was the reason for the migration; Parakeet now ships. -->
	<section class="research" id="research">
		<p class="eyebrow">Research · measured 30 July 2026</p>
		<h2>I measured 35 dictation pipelines instead of guessing</h2>
		<p class="research-intro">
			Dictation here is two stages: a speech engine turns audio into words, then a
			small local model cleans the words up. I had spent months tuning the second
			stage. So I built a harness and measured the whole grid — seven on-device speech
			engines against five cleanup options, 35 pipelines, all scored on the same
			116-second recording of me talking the way I actually talk: unscripted,
			disfluent, full of work jargon. Accuracy is word error rate against a reference
			I hand-wrote of what I <em>meant</em> to say, so a cleanup model isn't punished
			for deleting an "um".
		</p>
		<p class="research-intro">
			It reorganised the roadmap. Nearly all of the available accuracy sits in the
			engine. Almost none of it is in the prompt I'd been fiddling with.
		</p>

		<div class="stat-grid">
			{#each researchStats as s (s.label)}
				<div class="stat">
					<p class="stat-value">
						{s.value}{#if s.unit}<span class="stat-unit">{s.unit}</span>{/if}
					</p>
					<p class="stat-label">{s.label}</p>
					<p class="stat-note">{s.note}</p>
				</div>
			{/each}
		</div>

		<div class="ledger">
			<div class="ledger-col ledger-before">
				<h3>What the bake-off found</h3>
				<p class="ledger-value">38.1%</p>
				<p class="ledger-unit">word error rate — the pipeline I was shipping</p>
				<p>
					Apple's <code>SpeechTranscriber</code> plus Apple's on-device cleanup. It
					recovered 1 of 5 jargon terms, and the cleanup pass was a no-op on 4 of 7
					transcripts. Cleanup cost 4–9 seconds and bought about a point.
				</p>
			</div>
			<div class="ledger-col ledger-after">
				<h3>What ships now</h3>
				<p class="ledger-value">24.2%</p>
				<p class="ledger-unit">word error rate — Parakeet TDT v3, no cleanup</p>
				<p>
					Parakeet TDT v3 — 13.9 points better than the old pipeline on identical
					audio, and faster at the same time: 263× real time against Apple's 101×.
					It handled names and proper nouns better too. The cleanup stage is gone
					entirely — the engine is the whole game, and the app ships the engine
					the benchmark pointed at.
				</p>
			</div>
		</div>

		<div class="research-long">
			<h3>What happened on an hour of meeting audio</h3>
			<p>
				Short clips are the easy case, so I ran the same engines over a 57.5-minute
				recording with four speakers. Parakeet produced the whole transcript in 11.7
				seconds — 295× real time — with no drop in quality across the hour, and local
				diarization found exactly four speakers across 179 turns, attributing 97% of
				the audio. Whisper large-v3-turbo needed 84 seconds for the same file; Apple's
				engine with diarization needed 109. The most accurate engine on short audio,
				Qwen3-ASR 1.7B at 18.6%, fell apart here: about 38 minutes to process 57, which
				rules it out for meetings no matter how well it scores on a two-minute clip.
			</p>
		</div>

		<div class="trust">
			<h3>How much to trust this</h3>
			<ul>
				{#each trustNotes as n (n.lead)}
					<li><strong>{n.lead}</strong> {n.body}</li>
				{/each}
			</ul>
			<p class="trust-more">
				The full method, all 35 cells, and the charts are being written up on
				<a href="https://drkpxl.com" target="_blank" rel="noopener noreferrer"
					>drkpxl.com</a
				>. The harness itself lives in the
				<a
					href="https://github.com/drkpxl/better-voice"
					target="_blank"
					rel="noopener noreferrer">Better Voice repo</a
				>, so you can disagree with my scoring.
			</p>
		</div>
	</section>

	<!-- Compare: the honest pitch — one app instead of three subscriptions -->
	<section class="compare">
		<h2>One app instead of three subscriptions</h2>
		<p class="compare-intro">
			The usual setup: pay for a dictation app, pay for an AI notetaker, and
			keep your meetings in yet another company's cloud. Better Voice does both
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
					Press your hotkey and talk. Parakeet TDT v3 transcribes on-device,
					filler words are removed deterministically, and the text lands at
					your cursor — email, chat, code, notes. No window to switch to,
					nothing uploaded.
				</p>
			</div>
			<div>
				<h3>Meeting notes</h3>
				<p>
					Start a recording from the menu bar, drop in a file, or paste a
					transcript — Better Voice transcribes it, figures out who said what,
					names the voices, and writes a clean summary. It lands in Apple Notes
					as a titled note, transcript included. No new app to check: your
					summary is a normal Apple Note, already in the workflow you have. Mac-native,
					just like you are.
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

	<!-- Maker: the anti-social-proof section. Two users is the real number; say it. -->
	<section class="maker">
		<div class="maker-card">
			<h2>Two users, and one of them is me</h2>
			<p>
				That's the honest count. Better Voice is a one-person project — mine, built
				under the name Baseline Makes — so there are no logos to put in a row here and
				no reviews to quote. What I can offer instead is the work above: I measure
				before I ship, I publish the numbers including the ones that make my own
				choices look bad, and the app is free and MIT-licensed either way. If that
				seems like a reasonable trade, the download is right below.
			</p>
		</div>
	</section>

	<!-- Privacy callout -->
	<section class="privacy">
		<div class="privacy-card">
			<h2>Your audio never leaves your Mac</h2>
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
		color: var(--color-on-accent);
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
	.research,
	.compare,
	.why,
	.features,
	.maker,
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

	/* Anchored sections sit under the sticky header, so give the jump targets clearance. */
	.research,
	.features,
	.download {
		scroll-margin-top: 5rem;
	}

	/* Research — the evidence section. Numbers are mono and tabular so the columns line
	   up the way they do on the chart page this data came from. */
	.research h2 {
		margin-bottom: var(--space-md);
		max-width: 34ch;
	}

	.research .eyebrow {
		margin-bottom: var(--space-sm);
	}

	.research-intro {
		color: var(--color-text-muted);
		line-height: 1.7;
		max-width: 70ch;
		margin-bottom: var(--space-md);
	}

	/* Explicit breakpoints rather than auto-fit: there are exactly four stats, and auto-fit
	   lands on 3 + 1 at tablet width, which leaves a visible empty cell in the hairline grid. */
	.stat-grid {
		display: grid;
		grid-template-columns: 1fr;
		gap: 1px;
		background-color: var(--color-border-light);
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		overflow: hidden;
		margin-top: var(--space-lg);
	}

	@media (min-width: 520px) {
		.stat-grid {
			grid-template-columns: 1fr 1fr;
		}
	}

	@media (min-width: 900px) {
		.stat-grid {
			grid-template-columns: repeat(4, 1fr);
		}
	}

	.stat {
		background-color: var(--color-bg-card);
		padding: var(--space-md) var(--space-md) var(--space-lg);
	}

	.stat-value {
		font-family: var(--font-mono);
		font-size: 1.75rem;
		font-weight: 600;
		letter-spacing: -0.02em;
		font-variant-numeric: tabular-nums;
		color: var(--color-accent);
		line-height: 1.1;
		margin: 0;
	}

	.stat-unit {
		font-size: 0.9375rem;
		font-weight: 400;
		color: var(--color-text-muted);
		margin-left: 0.3em;
	}

	.stat-label {
		font-family: var(--font-mono);
		font-size: 0.6875rem;
		text-transform: uppercase;
		letter-spacing: 0.1em;
		color: var(--color-text-muted);
		margin: var(--space-sm) 0 var(--space-sm);
	}

	.stat-note {
		font-size: 0.875rem;
		line-height: 1.55;
		color: var(--color-text-muted);
		margin: 0;
	}

	/* Ledger: what the bake-off found vs. what ships now. Deliberately shaped
	   like the compare grid so "before" reading worse than "after" is unmissable. */
	.ledger {
		display: grid;
		grid-template-columns: 1fr;
		gap: var(--space-lg);
		margin-top: var(--space-lg);
	}

	@media (min-width: 768px) {
		.ledger {
			grid-template-columns: 1fr 1fr;
			gap: var(--space-xl);
		}
	}

	.ledger-col {
		background-color: var(--color-bg-card);
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		padding: var(--space-lg);
	}

	.ledger-after {
		border-left: 4px solid var(--color-accent);
	}

	.ledger-col h3 {
		font-family: var(--font-mono);
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.12em;
		color: var(--color-text-muted);
		margin-bottom: var(--space-md);
		display: flex;
		align-items: center;
		gap: 0.6rem;
		flex-wrap: wrap;
	}

	.ledger-after h3 {
		color: var(--color-accent);
	}

	.tag {
		font-family: var(--font-mono);
		font-size: 0.625rem;
		letter-spacing: 0.08em;
		text-transform: uppercase;
		padding: 0.1rem 0.4rem;
		border: 1px solid currentColor;
		border-radius: 4px;
		color: var(--color-text-muted);
	}

	.ledger-value {
		font-family: var(--font-mono);
		font-size: 2.5rem;
		font-weight: 600;
		letter-spacing: -0.03em;
		font-variant-numeric: tabular-nums;
		line-height: 1;
		margin: 0;
	}

	.ledger-before .ledger-value {
		color: var(--color-text-muted);
	}

	.ledger-after .ledger-value {
		color: var(--color-accent);
	}

	.ledger-unit {
		font-family: var(--font-mono);
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.08em;
		color: var(--color-text-muted);
		margin: var(--space-sm) 0 var(--space-md);
	}

	.ledger-col p:last-child {
		color: var(--color-text-muted);
		font-size: 0.9375rem;
		line-height: 1.65;
		margin: 0;
	}

	.ledger-col code {
		font-family: var(--font-mono);
		font-size: 0.85em;
		background-color: var(--color-bg-alt);
		padding: 0.05rem 0.35rem;
		border-radius: 4px;
	}

	/* Long-audio result + the caveat list */
	.research-long,
	.trust {
		margin-top: var(--space-lg);
	}

	.research-long h3,
	.trust h3 {
		font-family: var(--font-mono);
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.12em;
		color: var(--color-accent);
		margin-bottom: var(--space-sm);
	}

	.research-long p {
		color: var(--color-text-muted);
		line-height: 1.7;
		max-width: 72ch;
		margin: 0;
	}

	.trust ul {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--space-md);
		margin: 0;
	}

	.trust li {
		padding-left: var(--space-md);
		border-left: 2px solid var(--color-border);
		color: var(--color-text-muted);
		font-size: 0.9375rem;
		line-height: 1.65;
		max-width: 76ch;
	}

	.trust li strong {
		color: var(--color-text);
		font-weight: var(--weight-bold);
	}

	.trust-more {
		font-size: 0.875rem;
		line-height: 1.65;
		color: var(--color-text-muted);
		margin-top: var(--space-lg);
		max-width: 72ch;
	}

	/* Maker callout — mirrors the privacy card so the two honesty statements match */
	.maker-card {
		background-color: var(--color-bg-card);
		border: 1px solid var(--color-border-light);
		border-radius: var(--border-radius);
		padding: var(--space-lg);
		border-left: 4px solid var(--color-accent);
	}

	.maker-card h2 {
		margin-bottom: var(--space-md);
	}

	.maker-card p {
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

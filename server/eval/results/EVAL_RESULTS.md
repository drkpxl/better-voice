# WE Evaluation Results Report

Evaluation date: 2026-03-18
Device: Mac Mini M4 (10-core CPU, 16GB RAM), macOS 26

## Test Variables

| Variable | Value |
|------|---|
| Transcription engine | Apple SpeechAnalyzer (macOS 26), inputAudioFile API |
| L1 AlternativeSwap | Not enabled (meeting mode does not use L1) |
| L2 Polish (ollama) | Not enabled (meeting mode does not use L2) |
| Speaker diarization | FluidAudio performCompleteDiarization, offline, default DiarizerConfig |
| Alignment logic | WE alignTranscriptionWithDiarization (time-overlap matching) |
| Export | WE MeetingExporter (Markdown) |
| CER evaluation tool | jiwer 4.0.0 (standard tool) |
| DER evaluation tool | spyder 0.4.1 / fluidaudiocli built-in evaluation (standard tool) |

## Test 1: WE End-to-End Meeting Mode — Far-field

- **Pipeline**: MeetingSession.runFromFile() full pipeline
- **Dataset**: AliMeeting Eval far-field ch0 (single channel taken from 8-channel array, no beamforming)
- **Sessions**: 8 Chinese meetings, 2-4 speakers, 26-37 minutes/session, overlap rate >30%

| ID | CER% | Segments | Speakers (detected/actual) | RTFx | Duration |
|---|---|---|---|---|---|
| R8009_M8018 | 24.2 | 109 | 2/2 | 76.6 | 21.6s |
| R8009_M8020 | 24.7 | 129 | 1/2 | 85.1 | 22.4s |
| R8009_M8019 | 30.9 | 141 | 2/2 | 88.6 | 22.3s |
| R8003_M8001 | 33.7 | 143 | 3/4 | 81.6 | 25.3s |
| R8008_M8013 | 37.0 | 181 | 2/3 | 74.0 | 30.3s |
| R8007_M8011 | 38.5 | 127 | 2/4 | 77.1 | 24.1s |
| R8001_M8004 | 51.7 | 122 | 4/4 | 73.7 | 21.4s |
| R8007_M8010 | 62.1 | 152 | 6/4 | 81.0 | 22.9s |
| **Overall** | **40.0** | | | | |

## Test 2: WE End-to-End Meeting Mode — Near-field

- **Pipeline**: MeetingSession.runFromFile() full pipeline
- **Dataset**: AliMeeting Eval near-field (one headset mic per person, single speaker)
- **Sessions**: 25 speaker files, grouped by meeting

| Meeting | Average CER% | Speaker count |
|---|---|---|
| R8008_M8013 | 17.8 | 3 |
| R8001_M8004 | 22.8 | 4 |
| R8009_M8019 | 23.7 | 2 |
| R8009_M8018 | 24.0 | 2 |
| R8007_M8010 | 25.9 | 4 |
| R8007_M8011 | 27.4 | 4 |
| R8009_M8020 | 39.3 | 2 |
| R8003_M8001 | 110.1 | 4 (severe hallucination for 2 speakers, outlier) |
| **Overall** | **34.0** | |
| **Outliers excluded** | **~25%** | |

## Test 3: FluidAudio Component-Level Diarization — AMI

- **Pipeline**: fluidaudiocli diarization-benchmark (not the WE pipeline, component baseline)
- **Dataset**: AMI test set, 16 English sessions, 3-4 speakers, 14-50 minutes/session
- **DER evaluation**: fluidaudiocli built-in (collar=0.25s, ignoreOverlap=True)

| Metric | Value |
|---|---|
| Average DER | 23.2% |
| Average RTFx | 130.9x |
| DER range | 7.7% - 72.6% |

Best 3 sessions: IS1009c (7.7%), IS1009b (7.7%), TS3003b (9.9%)
Worst 2 sessions: ES2004d (69.4%), EN2002a (72.6%) — speaker error dominates (62%, 59%)

## Test 4: FluidAudio Component-Level Diarization — AliMeeting

- **Pipeline**: fluidaudiocli process --mode offline → spyder DER (not the WE pipeline, component baseline)
- **Dataset**: AliMeeting Eval far-field ch0, 8 Chinese sessions

| Metric | Value |
|---|---|
| Overall DER | 48.5% |
| Miss | 21.6% |
| False Alarm | 2.7% |
| Confusion | 24.1% |
| RTFx | ~131x |

## Test 5: Memory Usage

For a 30-40 minute meeting, diarization offline process-level peak:
- RSS: ~500MB
- Peak memory footprint: 730-930MB
- No pressure on 8GB devices

## Comparison Summary

| Condition | Overall CER | Notes |
|---|---|---|
| WE far-field | 40.0% | 8ch array ch0, no beamforming, high overlap |
| WE near-field | 34.0% (outliers excluded ~25%) | Headset mic, single speaker |
| Near-field vs far-field | -6pp (outliers excluded -15pp) | Near-field significantly outperforms far-field |

## Untested Items

- [ ] Impact of L1 AlternativeSwap on CER (everyday transcription mode)
- [ ] Impact of L2 Polish (ollama) on CER (everyday transcription mode)
- [ ] Full everyday transcription mode pipeline (short audio scenarios)
- [ ] English transcription CER/WER
- [ ] 5+ speaker scenarios
- [ ] DER for near-field mixed audio
- [ ] End-to-end cpWER (meeteval)

## Result Files

```
results/
├── ami_diarization/          # Test 3: AMI 16 sessions JSON + summary
├── alimeeting_diarization/   # Test 4: AliMeeting 8 sessions JSON + RTTM + DER
├── we_meeting_e2e/           # Test 1: WE far-field end-to-end 8 sessions JSON + CER + comparison
├── we_nearfield_transcription/ # Test 2: WE near-field 25 JSON + CER
└── EVAL_RESULTS.md           # this file
```

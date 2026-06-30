# §3.2 L4 ① Short Command Accuracy — Actual Results

100 samples; 41 fully correct, 59 inconsistent. Sorted below by "failures → CER descending".

Note: ground_truth comes from voice-history.finalText (historical L2 output); the differences from today's L2 output include both ① actual recognition errors and ② drift between the old L2 and the new L2.

---

## [FAIL] s054 (CER=14.357)
- ground_truth: `Um, okay, help me install it and see.`
- hypothesis  : `Okay, let me carefully look at the user's request. The user said, "Um, okay, help me install it and see." This sentence looks like it's asking how to install some piece of software. But the corrected final text needs to remove the filler words and fix the punctuation. The filler word "um" in the original sentence is redundant; after removing it, it becomes "Um, okay, help me install it and see." The punctuation fix adjusted the position of the comma. The user's prior history shows that previous replies all directly executed commands, but this time the user may be testing the speech recognition correction feature, so the original meaning should not be changed — only grammar errors should be fixed. After confirming there are no issues, output the corrected final text.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T08-21-27Z.wav`

## [FAIL] s063 (CER=5.100)
- ground_truth: `Um, okay, let's get started.`
- hypothesis  : `Okay, I'll correct the speech recognition error. The original sentence is "Um, okay, let's get started." The corrected final text is "Okay, let's get started." Filler words removed, punctuation corrected.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-15T02-22-43Z.wav`

## [FAIL] s047 (CER=2.000)
- ground_truth: `Hello.`
- hypothesis  : `Hello hello hello hello.`
- audio: `/Users/marvin/.we/audio/2026-03-12T06-31-34Z.wav`

## [FAIL] s081 (CER=1.350)
- ground_truth: `In addition, there's also the heartbeat mechanism and similar features like the learning class.`
- hypothesis  : `And then there's also. There's also some heartbeat mechanism, and some, like, um. The learning class and things like that, similar to that`
- audio: `/Users/marvin/.we/audio/2026-03-17T08-25-12Z.wav`

## [FAIL] s007 (CER=1.095)
- ground_truth: `I will create a card-style visualization display for the following three items.`
- hypothesis  : `This, this, I'll definitely do a visualization for the next three sections. Show it to me in a card display`
- audio: `/Users/marvin/.we/audio/2026-03-23T06-09-03Z.wav`

## [FAIL] s005 (CER=1.000)
- ground_truth: `Um, what does this have to do with how exactly it's done.`
- hypothesis  : `Login password`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T08-48-19Z.wav`

## [FAIL] s011 (CER=1.000)
- ground_truth: `Hello, how can I help you?`
- hypothesis  : `I want to test your accuracy.`
- audio: `/Users/marvin/.we/audio/2026-03-10T06-33-46Z.wav`

## [FAIL] s076 (CER=1.000)
- ground_truth: `What we're using is the reduced value.`
- hypothesis  : `Now, now?`
- audio: `/Users/marvin/.we/audio/remote-2026-04-17T05-52-55Z.wav`

## [FAIL] s078 (CER=0.962)
- ground_truth: `Um, let me test it first. If the connection is normal, then I'll test it again.`
- hypothesis  : `I've finished executing it`
- audio: `/Users/marvin/.we/audio/remote-2026-04-13T02-16-06Z.wav`

## [FAIL] s009 (CER=0.913)
- ground_truth: `Um, the specific implementation of this TQTQ may need further confirmation.`
- hypothesis  : `It's Tailscale.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T08-57-02Z.wav`

## [FAIL] s057 (CER=0.846)
- ground_truth: `That doesn't matter, let's set it aside for now.`
- hypothesis  : `This, this kind, set aside, lots of talk, doesn't matter.`
- audio: `/Users/marvin/.we/audio/2026-03-13T08-10-41Z.wav`

## [FAIL] s067 (CER=0.824)
- ground_truth: `OK, uh, let's see if zhēnliàng zhuāqù has an API?`
- hypothesis  : `OK, let's see if Tailscale grab has mail?`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T05-17-45Z.wav`

## [FAIL] s016 (CER=0.750)
- ground_truth: `Help me check whether I just switched to`
- hypothesis  : `Help me check whether I just Clyton this s at`
- audio: `/Users/marvin/.we/audio/remote-2026-04-13T08-31-09Z.wav`

## [FAIL] s035 (CER=0.750)
- ground_truth: `We also need to consider the editing settings, for example the factors need to be weighted more heavily.`
- hypothesis  : `Um, just take care of those editing settings, like the factors need to be heavier and heavier.`
- audio: `/Users/marvin/.we/audio/2026-03-17T05-30-38Z.wav`

## [FAIL] s058 (CER=0.750)
- ground_truth: `Okay okay`
- hypothesis  : `Okay`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T07-42-13Z.wav`

## [FAIL] s084 (CER=0.750)
- ground_truth: `Please refer to the official documentation.`
- hypothesis  : `Please go learn about the official documentation.`
- audio: `/Users/marvin/.we/audio/2026-03-23T08-46-18Z.wav`

## [FAIL] s092 (CER=0.739)
- ground_truth: `I not only need to look at the specific data results, but also pay attention to the execution effectiveness.`
- hypothesis  : `The process, well, I not only need to look at some specific data results, I need to look at some of its execution results and.`
- audio: `/Users/marvin/.we/audio/2026-03-18T06-01-27Z.wav`

## [FAIL] s018 (CER=0.722)
- ground_truth: `Hello, I tried the conversion feature, but it was unsuccessful.`
- hypothesis  : `Hello, let me try again to see if it can convert.`
- audio: `/Users/marvin/.we/audio/2026-03-10T06-13-37Z.wav`

## [FAIL] s021 (CER=0.700)
- ground_truth: `I guess you're not the executor.`
- hypothesis  : `I said you are the checker, not the executor.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T08-00-58Z.wav`

## [FAIL] s013 (CER=0.625)
- ground_truth: `Let me test whether there is a screen recording feature.`
- hypothesis  : `Let me try whether there's a screen recording feature.`
- audio: `/Users/marvin/.we/audio/2026-03-12T03-06-03Z.wav`

## [FAIL] s040 (CER=0.591)
- ground_truth: `Use the Spin feature of Cloud Console.`
- hypothesis  : `Use, definitely use, Claude Code's spin.`
- audio: `/Users/marvin/.we/audio/2026-03-16T09-16-51Z.wav`

## [FAIL] s002 (CER=0.474)
- ground_truth: `Let's test it — do you currently have a situation of overlapping users?`
- hypothesis  : `Let's test it, do you currently have user concurrency?`
- audio: `/Users/marvin/.we/audio/2026-03-10T08-41-38Z.wav`

## [FAIL] s012 (CER=0.429)
- ground_truth: `Hello, I'd like to try your KQ language.`
- hypothesis  : `Hi, I'd like to try your KE language I.`
- audio: `/Users/marvin/.we/audio/2026-03-10T06-33-31Z.wav`

## [FAIL] s053 (CER=0.429)
- ground_truth: `Let's try it, is there a wrong character used right now?`
- hypothesis  : `Let's try it, do you currently have error correction or not.`
- audio: `/Users/marvin/.we/audio/2026-03-10T08-41-24Z.wav`

## [FAIL] s097 (CER=0.429)
- ground_truth: `Um, put it in one directory, just put it under the AndyTarget directory.`
- hypothesis  : `Put it in one directory, just put it under the GitHub repository directory.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T08-21-35Z.wav`

## [FAIL] s008 (CER=0.412)
- ground_truth: `Let me test whether this data link is valid.`
- hypothesis  : `Let me try whether this data link can pass.`
- audio: `/Users/marvin/.we/audio/2026-03-19T03-10-50Z.wav`

## [FAIL] s044 (CER=0.400)
- ground_truth: `A practical problem.`
- hypothesis  : `A practical problem, I guess.`
- audio: `/Users/marvin/.we/audio/2026-03-13T02-03-42Z.wav`

## [FAIL] s004 (CER=0.364)
- ground_truth: `Uh, he can turn it into that flywheel`
- hypothesis  : `He can turn it into that`
- audio: `/Users/marvin/.we/audio/remote-2026-04-13T07-36-17Z.wav`

## [FAIL] s023 (CER=0.364)
- ground_truth: `Um, I didn't tell you to execute it.`
- hypothesis  : `I didn't tell you to execute it, OK.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T05-09-03Z.wav`

## [FAIL] s071 (CER=0.333)
- ground_truth: `OK, let me try this and see if it works like this?`
- hypothesis  : `OK, let me try this method?`
- audio: `/Users/marvin/.we/audio/remote-2026-04-09T08-32-12Z.wav`

## [FAIL] s072 (CER=0.267)
- ground_truth: `Secondary dev tale scele branch off main line.`
- hypothesis  : `Secondary dev Tailscale branch off main line.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T03-13-17Z.wav`

## [FAIL] s033 (CER=0.263)
- ground_truth: `Um, the agent definitely can't, can't be discounted, right.`
- hypothesis  : `Um, 27 definitely can't, can't be discounted, right.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T09-29-02Z.wav`

## [FAIL] s075 (CER=0.235)
- ground_truth: `Hey, let me try whether I can hear my own voice.`
- hypothesis  : `Let me try whether I can hear my voice.`
- audio: `/Users/marvin/.we/audio/2026-03-12T08-24-03Z.wav`

## [FAIL] s003 (CER=0.222)
- ground_truth: `Um, will it affect other deployments? If it affects deployment`
- hypothesis  : `Um, will it affect other configurations? If it affects its.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T02-27-02Z.wav`

## [FAIL] s038 (CER=0.222)
- ground_truth: `Um, let's check today's gitup project status.`
- hypothesis  : `Let's check today's GitHub project status.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T03-58-18Z.wav`

## [FAIL] s069 (CER=0.222)
- ground_truth: `Um, give me the current configuration`
- hypothesis  : `Um, give me the current status`
- audio: `/Users/marvin/.we/audio/remote-2026-04-17T05-05-34Z.wav`

## [FAIL] s080 (CER=0.200)
- ground_truth: `Let's change it, let's change it.`
- hypothesis  : `Change it, change it.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T07-31-12Z.wav`

## [FAIL] s087 (CER=0.200)
- ground_truth: `Um, let's first align on our understanding`
- hypothesis  : `First align on our understanding`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T03-04-47Z.wav`

## [FAIL] s006 (CER=0.185)
- ground_truth: `And then what I'm using is remote deser top destop.`
- hypothesis  : `And then what I'm using is remote desktop top desktop.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T02-46-40Z.wav`

## [FAIL] s028 (CER=0.182)
- ground_truth: `Just generate an output content for me.`
- hypothesis  : `Just organize an output content for me.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T06-18-35Z.wav`

## [FAIL] s019 (CER=0.154)
- ground_truth: `Is it feasible to change MCP to CLI?`
- hypothesis  : `Is it feasible to upgrade MC to CLI?`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T03-14-53Z.wav`

## [FAIL] s037 (CER=0.133)
- ground_truth: `The third one, I think it's settled, you can draft it.`
- hypothesis  : `The third one, I think you confirm, you can draft it.`
- audio: `/Users/marvin/.we/audio/2026-04-27T03-59-41Z.wav`

## [FAIL] s051 (CER=0.133)
- ground_truth: `Um, let me try first and see if this works.`
- hypothesis  : `Let me try first and see if this works.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T02-40-04Z.wav`

## [FAIL] s061 (CER=0.133)
- ground_truth: `Uh, open yesterday's daily report, let me take a look.`
- hypothesis  : `Open yesterday's daily report, let me take a look.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T03-15-03Z.wav`

## [FAIL] s089 (CER=0.125)
- ground_truth: `Testing the underwater module.`
- hypothesis  : `Testing underwater module.`
- audio: `/Users/marvin/.we/audio/2026-03-10T08-55-06Z.wav`

## [FAIL] s055 (CER=0.111)
- ground_truth: `Um, if something goes wrong, what's the recovery command?`
- hypothesis  : `Um, if something goes wrong, what's the restore command?`
- audio: `/Users/marvin/.we/audio/remote-2026-04-13T02-20-31Z.wav`

## [FAIL] s059 (CER=0.105)
- ground_truth: `Let me try this of yours. How's the selection rate, can it succeed?`
- hypothesis  : `Let me try this of yours. How's the recognition rate, can it succeed?`
- audio: `/Users/marvin/.we/audio/2026-03-12T02-11-04Z.wav`

## [FAIL] s083 (CER=0.091)
- ground_truth: `Um, I don't know whether you and I are aligned on this feature logic.`
- hypothesis  : `I don't know whether you and I are aligned on this feature logic.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T07-13-08Z.wav`

## [FAIL] s034 (CER=0.087)
- ground_truth: `Uh, send me status updates on a schedule, update the status every 5 minutes.`
- hypothesis  : `Send me status updates on a schedule, update the status every 5 minutes.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-17T03-39-29Z.wav`

## [FAIL] s093 (CER=0.083)
- ground_truth: `Um, I've already made a few modifications, go with my final result.`
- hypothesis  : `I've already made a few modifications, go with my final result.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-13T10-07-28Z.wav`

## [FAIL] s060 (CER=0.080)
- ground_truth: `Um, okay, let's check the recent project status, see if there are any updates.`
- hypothesis  : `Okay, let's check the recent project status, see if there are any updates.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T02-53-47Z.wav`

## [FAIL] s049 (CER=0.077)
- ground_truth: `Um, help me check this, uh, version on my local Windows machine.`
- hypothesis  : `Um, help me check this version on my local Windows machine.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T05-35-01Z.wav`

## [FAIL] s073 (CER=0.074)
- ground_truth: `Um, stop for a moment, stop for a moment, wait for me to run it again, if I run it again it'll easily OOM.`
- hypothesis  : `Um, stop for a moment, stop for a moment, wait for me to run it again, running it again in a bit will easily OOM.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-17T02-58-27Z.wav`

## [FAIL] s024 (CER=0.053)
- ground_truth: `And then the project name should be autoemail.`
- hypothesis  : `And then the project name should be auto-mail.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T02-09-22Z.wav`

## [FAIL] s020 (CER=0.043)
- ground_truth: `Help me with a local AS interpretation, after the file help me add one to the next.`
- hypothesis  : `Help me with a local AR interpretation, after the file help me add one to the next.`
- audio: `/Users/marvin/.we/audio/2026-03-23T05-48-59Z.wav`

## [FAIL] s036 (CER=0.043)
- ground_truth: `Uh, this is, um, only after understanding this do you truly understand what I said, OK.`
- hypothesis  : `This is, um, only after understanding this do you truly understand what I said, OK.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T05-07-57Z.wav`

## [FAIL] s095 (CER=0.038)
- ground_truth: `Um, or rather, do some things even better, with more, uh, depth/profundity.`
- hypothesis  : `Um, or rather, do some things even better, with more, uh, depth.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T06-11-09Z.wav`

## [FAIL] s065 (CER=0.036)
- ground_truth: `It's just that you shouldn't keep thinking, ah, that having A means B, and combining them into AB — that's completely wrong.`
- hypothesis  : `Just don't keep thinking, ah, that having A means B, and combining them into AB — that's completely wrong.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T05-04-19Z.wav`

## [FAIL] s043 (CER=0.000)
- ground_truth: `Remote desk top may manager。`
- hypothesis  : `Remote desktop may manager。`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T03-51-53Z.wav`

## [PASS] s001 (CER=0.000)
- ground_truth: `OK, let me try minimizing this window and see if it still works?`
- hypothesis  : `OK, let me try minimizing this window and see if it still works?`
- audio: `/Users/marvin/.we/audio/remote-2026-04-09T08-31-51Z.wav`

## [PASS] s010 (CER=0.000)
- ground_truth: `Why can't you connect, that's a problem — the fact that you can't connect is the problem.`
- hypothesis  : `Why can't you connect, that's a problem — the fact that you can't connect is the problem.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T08-28-06Z.wav`

## [PASS] s014 (CER=0.000)
- ground_truth: `OK, then let me try again and see if this test can succeed.`
- hypothesis  : `OK, then let me try again and see if this test can succeed.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-09T08-31-12Z.wav`

## [PASS] s015 (CER=0.000)
- ground_truth: `It's a tutorial, or maybe tutorial documentation.`
- hypothesis  : `It's a tutorial, or maybe tutorial documentation.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-09T08-38-01Z.wav`

## [PASS] s017 (CER=0.000)
- ground_truth: `Um, no other issues.`
- hypothesis  : `Um, no other issues.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T09-03-00Z.wav`

## [PASS] s022 (CER=0.000)
- ground_truth: `Um, let's align first, don't rush to write yet, let's align first and see.`
- hypothesis  : `Um, let's align first, don't rush to write yet, let's align first and see.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-15T09-46-46Z.wav`

## [PASS] s025 (CER=0.000)
- ground_truth: `Um, the webpage still won't open.`
- hypothesis  : `Um, the webpage still won't open.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T08-25-59Z.wav`

## [PASS] s026 (CER=0.000)
- ground_truth: `Um, that's pretty good, so I'll keep testing, see if there are any other issues.`
- hypothesis  : `Um, that's pretty good, so I'll keep testing, see if there are any other issues.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-09T08-31-20Z.wav`

## [PASS] s027 (CER=0.000)
- ground_truth: `Try it and see if it can reroute.`
- hypothesis  : `Try it and see if it can reroute.`
- audio: `/Users/marvin/.we/audio/remote-2026-05-15T02-07-39Z.wav`

## [PASS] s029 (CER=0.000)
- ground_truth: `Try it and see if it can reroute.`
- hypothesis  : `Try it and see if it can reroute.`
- audio: `/Users/marvin/.we/audio/remote-2026-05-14T08-28-11Z.wav`

## [PASS] s030 (CER=0.000)
- ground_truth: `You shouldn't, you couldn't possibly have a reply like that, you, um.`
- hypothesis  : `You shouldn't, you couldn't possibly have a reply like that, you, um.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-17T03-41-13Z.wav`

## [PASS] s031 (CER=0.000)
- ground_truth: `Uh, WEWE, not fine-tuned WE.`
- hypothesis  : `Uh, WEWE, not fine-tuned WE.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-20T03-01-14Z.wav`

## [PASS] s032 (CER=0.000)
- ground_truth: `I think I'm resting, nothing's wrong.`
- hypothesis  : `I think I'm resting, nothing's wrong.`
- audio: `/Users/marvin/.we/audio/2026-03-10T05-51-03Z.caf`

## [PASS] s039 (CER=0.000)
- ground_truth: `Uh, you can keep going, you can keep going.`
- hypothesis  : `Uh, you can keep going, you can keep going.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-24T08-21-30Z.wav`

## [PASS] s041 (CER=0.000)
- ground_truth: `I switched to a Tailscale, that should work, right.`
- hypothesis  : `I switched to a Tailscale, that should work, right.`
- audio: `/Users/marvin/.we/audio/2026-04-27T03-48-47Z.wav`

## [PASS] s042 (CER=0.000)
- ground_truth: `Um, keep going, um, and then, for the data acquisition layer, you, you keep writing first.`
- hypothesis  : `Um, keep going, um, and then, for the data acquisition layer, you, you keep writing first.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-17T01-35-57Z.wav`

## [PASS] s045 (CER=0.000)
- ground_truth: `Um, this way it should be audible too, this way there shouldn't be any issue either.`
- hypothesis  : `Um, this way it should be audible too, this way there shouldn't be any issue either.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-27T03-52-17Z.wav`

## [PASS] s046 (CER=0.000)
- ground_truth: `OK, then go live first and give it a try.`
- hypothesis  : `OK, then go live first and give it a try.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T07-45-43Z.wav`

## [PASS] s048 (CER=0.000)
- ground_truth: `Um, help me open it.`
- hypothesis  : `Um, help me open it.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T07-21-26Z.wav`

## [PASS] s050 (CER=0.000)
- ground_truth: `Try it, if not, let me see whether it can recognize and execute this way.`
- hypothesis  : `Try it, if not, let me see whether it can recognize and execute this way.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-27T03-43-48Z.wav`

## [PASS] s052 (CER=0.000)
- ground_truth: `And then, um, write one for me — oh, you've already written it, right, then open it.`
- hypothesis  : `And then, um, write one for me — oh, you've already written it, right, then open it.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-23T07-29-55Z.wav`

## [PASS] s056 (CER=0.000)
- ground_truth: `Um, reasonable, I think your final filtering dimension is reasonable.`
- hypothesis  : `Um, reasonable, I think your final filtering dimension is reasonable.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T02-05-50Z.wav`

## [PASS] s062 (CER=0.000)
- ground_truth: `Um. Right, then let's use that semantic distance, re-evaluate via semantic distance.`
- hypothesis  : `Um. Right, then let's use that semantic distance, re-evaluate via semantic distance.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-15T05-52-40Z.wav`

## [PASS] s064 (CER=0.000)
- ground_truth: `Um, help me open it with Antigravity.`
- hypothesis  : `Um, help me open it with Antigravity.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T07-21-56Z.wav`

## [PASS] s066 (CER=0.000)
- ground_truth: `It's not that the configuration isn't enabled below, it's that your local machine can't resolve this. IP address`
- hypothesis  : `It's not that the configuration isn't enabled below, it's that your local machine can't resolve this. IP address`
- audio: `/Users/marvin/.we/audio/2026-03-23T05-48-33Z.wav`

## [PASS] s068 (CER=0.000)
- ground_truth: `Test the modify feature.`
- hypothesis  : `Test the modify feature.`
- audio: `/Users/marvin/.we/audio/2026-03-10T08-54-56Z.wav`

## [PASS] s070 (CER=0.000)
- ground_truth: `Um, don't run verification, don't run verification.`
- hypothesis  : `Um, don't run verification, don't run verification.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T01-52-34Z.wav`

## [PASS] s074 (CER=0.000)
- ground_truth: `Try this and see if it works.`
- hypothesis  : `Try this and see if it works.`
- audio: `/Users/marvin/.we/audio/2026-04-27T03-46-00Z.wav`

## [PASS] s077 (CER=0.000)
- ground_truth: `Um, keep going, keep going.`
- hypothesis  : `Um, keep going, keep going.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-22T02-49-48Z.wav`

## [PASS] s079 (CER=0.000)
- ground_truth: `Um, isn't Docker being used?`
- hypothesis  : `Um, isn't Docker being used?`
- audio: `/Users/marvin/.we/audio/remote-2026-04-15T06-01-38Z.wav`

## [PASS] s082 (CER=0.000)
- ground_truth: `Um, keep going, keep going.`
- hypothesis  : `Um, keep going, keep going.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T07-32-31Z.wav`

## [PASS] s085 (CER=0.000)
- ground_truth: `Um, if there's no problem, let's go with this for now.`
- hypothesis  : `Um, if there's no problem, let's go with this for now.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T01-58-26Z.wav`

## [PASS] s086 (CER=0.000)
- ground_truth: `Take a look and help me find out the reason.`
- hypothesis  : `Take a look and help me find out the reason.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T02-40-47Z.wav`

## [PASS] s088 (CER=0.000)
- ground_truth: `Um, no rush to train first, make sure you fully understand my architecture first.`
- hypothesis  : `Um, no rush to train first, make sure you fully understand my architecture first.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-15T08-56-48Z.wav`

## [PASS] s090 (CER=0.000)
- ground_truth: `Um, it seems directly copying some of that HDML code doesn't work.`
- hypothesis  : `Um, it seems directly copying some of that HDML code doesn't work.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T09-04-33Z.wav`

## [PASS] s091 (CER=0.000)
- ground_truth: `Um, can you create it? If you can create it, then help me create it.`
- hypothesis  : `Um, can you create it? If you can create it, then help me create it.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-16T08-13-29Z.wav`

## [PASS] s094 (CER=0.000)
- ground_truth: `Um, good, then this task is successfully completed.`
- hypothesis  : `Um, good, then this task is successfully completed.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-09T09-04-12Z.wav`

## [PASS] s096 (CER=0.000)
- ground_truth: `Um, confirm confirm`
- hypothesis  : `Um, confirm confirm`
- audio: `/Users/marvin/.we/audio/remote-2026-04-13T03-25-04Z.wav`

## [PASS] s098 (CER=0.000)
- ground_truth: `Um, let me test it, test it`
- hypothesis  : `Um, let me test it, test it`
- audio: `/Users/marvin/.we/audio/remote-2026-04-10T02-44-02Z.wav`

## [PASS] s099 (CER=0.000)
- ground_truth: `Uh, including your selection of standards, that is, the selection of your evaluation criteria is fine too.`
- hypothesis  : `Uh, including your selection of standards, that is, the selection of your evaluation criteria is fine too.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-15T06-08-21Z.wav`

## [PASS] s100 (CER=0.000)
- ground_truth: `And then for the first question, confirm what my Xcode version is.`
- hypothesis  : `And then for the first question, confirm what my Xcode version is.`
- audio: `/Users/marvin/.we/audio/remote-2026-04-14T02-57-12Z.wav`

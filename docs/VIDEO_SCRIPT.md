# Demo Video Script (target: ~4:20, under the 5:00 limit)

Format: facecam + voiceover, cut to screen capture for the demo/results parts.
Numbers below are real, pulled from `docs/REPORT.md` — don't round them up.
Timestamp labels below are approximate targets, not exact — actual pacing is driven
by the real recorded audio. Based on real segment durations: hook+what-it-does
facecam is ~88s, the live-run/results VO is ~44s, the new real-world segment is
~60-70s once recorded, the stress-test segment is ~57s, and the close is ~5s —
total ~4:15-4:25, comfortably under the 5:00 limit.

---

**[0:00–0:30] Face cam, hook + problem**

> "AWS sells a special, faster build of OpenCV called COOL, Cloud-Optimized OpenCV Library, optimized for their
> Graviton chips. The claim is simple: it's faster than regular OpenCV. But it's a
> paid product — there's no public way to check that claim before you pay for it.
> So I built an agent that checks it for you, automatically, on real AWS hardware,
> and shows its work — including the parts where COOL *doesn't* help."

**[0:30–1:15] Face cam, what it does**

> "This isn't a one-shot benchmark. It's an agent: it spins up a cheap AWS Graviton
> instance, installs a genuinely vanilla OpenCV as the baseline, runs a fixed set of
> real vision operations — resize, blur, edge detection, feature matching, warping —
> times it. Then it switches to COOL, same instance, same operations, times that.
> If COOL doesn't clear a target speedup, it doesn't just give up — it tries different
> thread configurations and tests again, like tuning a recipe, until it either hits the
> target or runs out of things to try. Then it reports exactly what happened — and the
> instance shuts itself down the second it's done, so it's not sitting there costing
> money."

**[1:15–2:30] Screen capture, live run**

- Show terminal / AWS console launching the instance (speed up if needed).
- Show the agent's live log output: baseline run → COOL run → evaluate → (if needed)
  next thread candidate → evaluate → verdict.
- Narration over it:

> "Here it is running for real. Baseline first — this is real OpenCV 5, installed
> fresh from PyPI, nothing rigged. Now COOL, same machine, same images. And here's
> the verdict: 35 percent faster, on the very first configuration it tried."

**[2:30–3:30] Screen capture, the results table / chart**

- Show the results table from the report: 10 independent runs, 1.29x–1.46x range,
  ~36% average, consistent across 480p/1080p/4K.
- Narration:

> "I didn't stop at one run. I repeated this four separate times, on fresh instances,
> across three different image resolutions — ten measurements total. Every single one
> landed between 29 and 46 percent faster, averaging right around 36 percent. This
> isn't a lucky number — it's consistent."

**[3:30–4:15] NEW SEGMENT — needs fresh recording. Face cam or VO over `scene_realworld.html`.**

This is now the most important part of the video — the real-world validation flips the
headline finding. Suggested read (edit freely, keep the numbers exact):

> "So that's the lab result — 36 percent faster, synthetic test images, textbook
> conditions. But synthetic isn't real. So I pushed it further: I had the agent
> download real photos — not test data, actual images — across the kinds of things
> this competition cares about: medical scans, farm fields, retail shelves, traffic
> cameras, industrial inspection, aerial shots. Same baseline, same COOL, same
> instance, nine real images.
>
> And the 36 percent fell apart. Averaged across all nine, COOL was only 6 percent
> faster — and it was actually *slower* than baseline in five of the nine images.
>
> Here's why: two of the five operations — resize and image warping — were
> consistently slower on COOL, every single image, no exceptions. Two others — blur
> and edge detection — were consistently faster, every time. The swing factor is
> feature detection: it's a strong win on images with lots of distinct objects —
> buildings, a crowd, products on a shelf — and barely helps, or even hurts, on
> uniform, repetitive content like a wheat field or dense foliage.
>
> So the claim isn't false. It's incomplete. Whether COOL actually helps you depends
> entirely on what you're processing — and that's exactly the kind of thing you'd
> never find out from a benchmark page."

**[4:15–4:45] Screen capture, the honest failure case (thread-count stress test)**

- Show the corrected stress-test table from `docs/REPORT.md`.

> "I also deliberately gave it a harder target — 1.6x — specifically to force it to
> try every option it had instead of stopping at the first success. It never hit
> 1.6x, and it told me that honestly instead of hiding it. What it did find: COOL is
> faster than baseline at every thread count I tested — it never gets worse — but the
> margin depends on parallelism. Single-threaded, it's only about 8 to 9 percent
> faster. With two or more threads, that jumps to 30 to 36 percent. COOL's speedup
> scales with how much parallelism you give it — that's the kind of detail you only
> get from actually stress-testing a claim, not from a headline number."

**[4:45–5:15] Face cam, close**

> "So: real baseline, real AWS Graviton hardware, an agent that adapts instead of
> running once, and results — good and bad — reported honestly. Code, the full
> methodology, and every raw result are in the repo. Thanks for watching."

---

## Shot list / things to have on screen

1. `docs/scene1_hook.html` — hook + what-it-does pipeline, with real OpenCV example
   images (resize/blur/edges/features/warp shown live)
2. `docs/scene2_race.html` — baseline vs. COOL race, paced by real per-op timing
3. `docs/scene_realworld.html` — **the new headline visual**: all 9 real test images
   with their speedup badges (green = faster, red = slower), the per-operation
   breakdown, and the "it depends on content" conclusion
4. `docs/scene3_stress.html` — thread-count stress-test chart
5. Architecture diagram (from `docs/REPORT.md`) — optional, if time allows

## Recording status

- ✅ Hook, what-it-does, live-run narration, synthetic results recap, stress-test
  narration, and close — all already recorded (see `clips/final_cut_v1.mp4` for the
  prior assembly; needs re-editing with the new segment inserted).
- ⬜ **New real-world validation segment (the [3:30–4:15] block above) still needs to
  be recorded** — this is the only new audio/facecam needed for the updated script.

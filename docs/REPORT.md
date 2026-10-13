# COOL Auto-Tuner — Technical Report

**OpenCV AI Competition 2026, powered by AWS**
Categories targeted: Best Use of COOL, Agentic Vision (also auto-entered for Tracks/Overall)

## Problem

AWS Marketplace sells [Cloud-Optimized OpenCV (COOL)](https://opencv.org/cool/) — a
build of OpenCV re-compiled for AWS Graviton (Arm Neoverse), claimed to run common
vision operations faster than a standard pip install. That claim is easy to make and
hard to verify: it's a paid Marketplace product, there's no public, reproducible,
apples-to-apples benchmark a developer can run themselves before committing budget to it.

**COOL Auto-Tuner is an agent that tests that claim automatically, on real AWS
hardware, with a real baseline, and reports the evidence — including when COOL
*doesn't* help.** It isn't a one-shot script: it runs a fixed benchmark against a
genuinely vanilla baseline, runs the same benchmark under COOL, evaluates whether COOL
cleared a target speedup, and if not, tries other configurations (thread counts) before
giving up — each next action chosen from the previous measurement, not a fixed script.

## Architecture

```mermaid
flowchart TD
    A[Agent launches AWS Graviton c8g.large<br/>from the COOL Marketplace AMI] --> B[Sets up baseline:<br/>isolated venv, pip install opencv-python-headless]
    B --> C[Discovers COOL's pre-built Python bindings<br/>on the AMI: LD_LIBRARY_PATH / PYTHONPATH]
    C --> D{For each resolution tier<br/>480p / 1080p / 4K}
    D --> E[Run fixed op suite under baseline<br/>resize, blur, Canny, ORB, warpAffine]
    E --> F[Run same suite under COOL<br/>at a candidate thread count]
    F --> G{Speedup >= target?}
    G -- yes --> H[Record TARGET_MET, move to next resolution]
    G -- no --> I{More thread candidates<br/>left to try?}
    I -- yes --> F
    I -- no --> J[Record TARGET_NOT_MET + best config found,<br/>move to next resolution]
    H --> D
    J --> D
    D -- all resolutions done --> K[Final report: per-resolution verdicts,<br/>full decision log, honest failure cases]
    K --> L[Instance self-terminates<br/>shutdown -h now]
```

Everything in the dashed region above runs on a single short-lived AWS Graviton
instance, driven by a startup script, with output captured from the instance's boot
console log — no SSH keys, no open security groups, no persistent server. The instance
terminates itself the moment it's done (see "Safety" below).

## Methodology

- **Hardware:** AWS `c8g.large` (2 vCPU, 4GB, Graviton, `arm64`), `us-east-1`.
- **Baseline:** `opencv-python-headless` 5.0.0, installed fresh from PyPI in an isolated
  venv. This matches the comparison basis COOL's own publisher uses in its benchmarks
  ("vs. pip OpenCV") — the AMI's vanilla C++ build (`/install-4x`) ships with no Python
  bindings at all, so it can't be benchmarked from Python directly; the pip venv is the
  correct, fair stand-in.
- **COOL:** the AMI's pre-built `/install-cool` Python bindings (OpenCV 4.14.0-pre),
  reached by discovering and injecting the correct `LD_LIBRARY_PATH`/`PYTHONPATH` at
  runtime (no hand-maintained paths).
- **Workload:** 20 synthetic images (fixed random seed, identical across every run),
  five common operations — resize, Gaussian blur, Canny edge detection, ORB
  detect+compute, affine warp — each timed over multiple repeats (10 for 480p/1080p, 4
  for 4K) with one untimed warmup call. Both mean and standard deviation are reported.
- **Resolutions tested:** 480p, 1080p, 4K.
- **Target speedup (standard runs):** 1.25x. **Stress-test target:** 1.6x, used
  specifically to force the agent to exhaust its thread-count candidates and prove the
  escalation logic actually runs, not just succeeds by luck on the first try.

## Results

### Standard runs (target: 1.25x) — 10 independent measurements across 4 separate instance launches

| Resolution | Run | Baseline total (s) | Speedup vs. baseline |
|---|---|---|---|
| 1080p | run3 | 1.927 | 1.350x |
| 480p / 1080p / 4K | run4 | 0.430 / 1.948 / 7.623 | 1.355x / 1.352x / 1.344x |
| 480p / 1080p / 4K | repro5 | — | 1.291x / 1.354x / 1.463x |
| 480p / 1080p / 4K | repro6 | — | 1.348x / 1.400x / 1.349x |

**Mean speedup across all 10 measurements: ~1.36x (COOL is ~36% faster than genuine
baseline OpenCV 5.0.0), range 1.29x–1.46x.** Every single measurement cleared the
1.25x target — the result is consistent, not a one-off.

### Stress test (target: 1.6x) — full thread-count sweep, all 3 resolutions

| Resolution | threads=default | threads=1 | threads=2 | threads=4 |
|---|---|---|---|---|
| 480p | 1.28x | **0.83x** | 1.34x | 1.36x |
| 1080p | 1.40x | **0.84x** | 1.40x | 1.37x |
| 4K | 1.35x | **0.80x** | 1.31x | 1.37x |

No configuration reached 1.6x — the agent correctly worked through all four
thread-count candidates for all three resolutions before reporting `TARGET_NOT_MET`,
which is the honest outcome, not a failure of the agent. More interesting: **forcing
single-threaded execution makes COOL ~17-20% *slower* than baseline**, consistently,
across every resolution tested — COOL's acceleration appears to depend on being allowed
to use more than one thread, a genuinely non-obvious finding this kind of automated,
adversarial-ish sweep is well suited to surface.

## Limitations / honest caveats

- Sample size is modest (10 standard measurements, one stress sweep) — enough to show
  consistency, not enough for formal statistical confidence intervals.
- Only one instance size (`c8g.large`) was tested; COOL's own Marketplace listings
  cover larger Graviton4/5 instance families we didn't benchmark.
- The workload is a fixed synthetic suite of common operations, not a real production
  pipeline — representative, but not identical to every real use case.
- The agent's thread-count exploration never needed to go beyond `threads=4`; whether
  larger thread counts behave differently on bigger instances is untested.

## Safety / cost discipline

Every instance launch is tagged, time-bounded (`timeout 280` around the agent's own
run), and self-terminates (`shutdown -h now`) at the end of its startup script,
independent of any external monitoring — this doesn't depend on a human or a polling
process noticing the run is done. Total AWS spend across the full build process: under
$1.

## Reproducing this

See [`infra/run-userdata.sh`](../infra/run-userdata.sh) (standard target) and
[`infra/run-userdata-stress.sh`](../infra/run-userdata-stress.sh) (1.6x stress target) —
either can be passed directly as EC2 user-data against the COOL Marketplace AMI
(`ami-033e481a24f94c8cb` in `us-east-1`, or the equivalent AMI ID for another region)
on a `c8g.large` or larger instance. Raw results are in [`benchmarks/`](../benchmarks/).

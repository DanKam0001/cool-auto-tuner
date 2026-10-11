# Build Plan

Deadline: Oct 26, 2026, 11:59pm Pacific. ~16 days from kickoff.

## What we need from AWS (human steps, done once)

1. IAM user `opencv-hackathon-agent`, programmatic access only, scoped policy (see
   `infra/iam-policy.json`).
2. A billing budget/alert set in AWS Budgets (recommend $20 threshold) so an idle
   instance can't run away unnoticed.
3. Manually accept the COOL Marketplace listing's EULA via the AWS console
   (Marketplace subscriptions generally require a one-time human click to accept
   software terms — this can't be done via CLI). Pick the cheapest Graviton variant
   that satisfies the "core workload runs via COOL" requirement.

## Build phases

1. **Scaffold + baseline (days 1-3):** repo structure, pick a target OpenCV pipeline
   to optimize (a public benchmark set of common ops: resize, blur, feature detection,
   etc.), get vanilla OpenCV running on a `t4g.small` (free-tier) Graviton instance as
   the baseline measurement.
2. **COOL integration (days 4-7):** subscribe to COOL, swap the baseline pipeline's
   core ops to COOL calls, confirm it actually executes on the Arm path (not silently
   falling back to vanilla), get first real before/after numbers.
3. **The agent loop (days 8-11):** build the actual developer-agent: given a pipeline,
   profile it, decide which ops to swap, run the benchmark, evaluate against a target
   (e.g. "beat baseline latency by X%"), iterate or report failure. This is the part
   that satisfies "Agentic Vision" — it has to actually use its own measurements to
   change what it does next, not just run once.
4. **Report + evaluation evidence (days 12-13):** technical report, architecture
   diagram, failure cases, reproducibility instructions.
5. **Video + submission (days 14-16):** demo video (screen capture of the agent
   running + narration), final Devpost submission.

## Cost control

- Always tear down the EC2 instance after a benchmark run — script this, don't rely
  on remembering (`infra/teardown.sh`).
- Use `t4g.small` for the vanilla baseline (free-tier eligible) and only the minimum
  Graviton size the COOL listing requires for the COOL runs.
- Never leave an instance running unattended overnight.

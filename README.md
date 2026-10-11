# OpenCV COOL Optimizer Agent

Built for the [OpenCV AI Competition 2026, powered by AWS](https://opencv-aws-2026.devpost.com/).

## What this is

A developer agent that takes an arbitrary OpenCV 5 pipeline, profiles it, iteratively
swaps in [Cloud-Optimized OpenCV (COOL)](https://opencv.org/cool/) calls where they help,
runs it on AWS Graviton, and benchmarks the result against a vanilla-OpenCV baseline on
the same instance — reporting real latency/throughput numbers, or reporting when it can't
hit the target.

This targets two award categories:
- **Best Use of COOL** — core workload actually executes via COOL on the Graviton/Arm path.
- **Agentic Vision** — the agent iteratively invokes, evaluates, and adjusts the OpenCV
  workload itself (a qualifying "developer-agent" pattern per the competition rules), not
  just a one-shot vision call.

## Status

Scaffolding in progress. See `docs/PLAN.md` for the build plan and `infra/` for the AWS
Graviton provisioning scripts.

## Repo layout

- `src/` — the optimizer agent itself
- `infra/` — AWS CLI/boto3 scripts to launch, benchmark, and tear down the Graviton instance
- `docs/` — technical report, architecture diagram, evaluation evidence (built up as we go)
- `benchmarks/` — raw benchmark output (before/after COOL, per target pipeline)

## License

TBD.

"""
The COOL Auto-Tuner agent. Run ON the Graviton instance, after the baseline
venv has been created and discover_envs.py has produced build_envs.json.

Baseline = a genuinely vanilla `opencv-python-headless` pip install in an
isolated venv (/tmp/baseline_venv). This matches the comparison basis COOL's
own publisher uses in their benchmarks ("vs. pip OpenCV") -- the AMI's
/install-4x build has no Python bindings at all, so it can't be imported
from Python directly; the pip venv is the correct, fair baseline.

COOL = the AMI's pre-built /install-cool Python bindings, reached via
LD_LIBRARY_PATH/PYTHONPATH discovered by discover_envs.py.

The actual "agentic" loop, not a one-shot call: for each resolution tier,
measure the baseline once, then try COOL across a set of thread-count
candidates, evaluating after each one -- the next candidate tried (or
whether to stop and move to the next resolution) is chosen based on the
previous measurement, not a fixed script. Every attempt is logged, so a
resolution where COOL doesn't help is reported as a real finding, not
hidden.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
BASELINE_PYTHON = "/tmp/baseline_venv/bin/python3"
TARGET_SPEEDUP = 1.25  # COOL must beat baseline by >=25% to "win" a config
THREAD_CANDIDATES = [-1, 4]  # -1 = let OpenCV pick its own default
RESOLUTIONS = ["480p", "1080p", "4k"]


def _run(python_bin: str, extra_env: dict, threads: int, resolution: str) -> dict:
    env = dict(os.environ)
    for k, v in extra_env.items():
        env[k] = f"{v}:{env.get(k, '')}"

    proc = subprocess.run(
        [python_bin, str(HERE / "workload.py"), str(threads), resolution],
        capture_output=True, text=True, timeout=300, env=env,
    )
    if proc.returncode != 0:
        return {"error": proc.stderr.strip() or "non-zero exit, no stderr"}
    try:
        return json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception as e:
        return {"error": f"could not parse workload output: {e}", "raw_stdout": proc.stdout}


def _tune_one_resolution(resolution: str, cool_extra_env: dict, log: list) -> dict:
    baseline_result = _run(BASELINE_PYTHON, {}, threads=-1, resolution=resolution)
    log.append({"step": "baseline_run", "resolution": resolution, "threads": -1, "result": baseline_result})

    if "error" in baseline_result:
        return {"resolution": resolution, "verdict": "FAILED", "reason": "baseline run failed"}

    baseline_total = baseline_result["total_seconds_mean"]
    best = None

    for threads in THREAD_CANDIDATES:
        result = _run("python3", cool_extra_env, threads, resolution)
        log.append({"step": "cool_run", "resolution": resolution, "threads": threads, "result": result})

        if "error" in result:
            continue

        speedup = baseline_total / result["total_seconds_mean"]
        result["_speedup_vs_baseline"] = speedup
        log.append({"step": "evaluate", "resolution": resolution, "threads": threads,
                    "speedup": speedup, "target": TARGET_SPEEDUP, "met_target": speedup >= TARGET_SPEEDUP})

        if best is None or speedup > best["_speedup_vs_baseline"]:
            best = result
            best["_threads_used"] = threads

        if speedup >= TARGET_SPEEDUP:
            return {
                "resolution": resolution, "verdict": "TARGET_MET",
                "baseline_total_seconds_mean": baseline_total,
                "best_config": {"threads": threads, "speedup_vs_baseline": speedup},
            }

    if best is None:
        return {"resolution": resolution, "verdict": "FAILED", "reason": "every COOL run errored"}

    return {
        "resolution": resolution, "verdict": "TARGET_NOT_MET",
        "baseline_total_seconds_mean": baseline_total,
        "best_config": {"threads": best["_threads_used"], "speedup_vs_baseline": best["_speedup_vs_baseline"]},
    }


def run_agent(build_envs_path: str) -> dict:
    with open(build_envs_path) as f:
        envs = json.load(f)

    cool_env = envs.get("cool", {})
    cool_extra_env = {"LD_LIBRARY_PATH": cool_env.get("lib_dir", "")}
    if cool_env.get("python_path"):
        cool_extra_env["PYTHONPATH"] = cool_env["python_path"]

    log = []
    per_resolution = [_tune_one_resolution(res, cool_extra_env, log) for res in RESOLUTIONS]

    met = [r for r in per_resolution if r["verdict"] == "TARGET_MET"]
    overall_verdict = "TARGET_MET_SOMEWHERE" if met else "TARGET_NOT_MET_ANYWHERE"

    return {
        "overall_verdict": overall_verdict,
        "target_speedup": TARGET_SPEEDUP,
        "per_resolution": per_resolution,
        "log": log,
    }


if __name__ == "__main__":
    build_envs_path = sys.argv[1] if len(sys.argv) > 1 else str(HERE / "build_envs.json")
    report = run_agent(build_envs_path)
    print("===AGENT_REPORT_START===")
    print(json.dumps(report, indent=2))
    print("===AGENT_REPORT_END===")

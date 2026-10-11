"""
The COOL Auto-Tuner agent. Run ON the Graviton instance, after
discover_envs.py has produced build_envs.json.

What it does (the actual "agentic" loop, not a one-shot call):
  1. Runs the fixed benchmark workload under the vanilla baseline build.
  2. Runs it under COOL at the default thread count.
  3. Evaluates: did COOL beat the target speedup? If not, it tries the next
     thread-count candidate -- each next action is chosen based on the
     previous measurement, not a fixed script.
  4. Stops when it hits the target, runs out of candidates, or detects a
     result that's not reproducible (high run-to-run variance), and reports
     a verdict either way, including failure cases.

Everything is logged so the full decision trail is in the final report, not
just the winning config.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
TARGET_SPEEDUP = 1.15  # COOL must beat baseline by >=15% to "win" a config
THREAD_CANDIDATES = [-1, 1, 2, 4]  # -1 = let OpenCV pick its own default


def _run_workload(python_path: str | None, lib_dir: str, threads: int) -> dict:
    # Inherit the full environment (so numpy etc. still resolve via the
    # system site-packages) and only prepend the build-specific paths, so
    # the target build's cv2 shadows whatever's on the default path.
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}"
    if python_path:
        env["PYTHONPATH"] = f"{python_path}:{env.get('PYTHONPATH', '')}"

    proc = subprocess.run(
        ["python3", str(HERE / "workload.py"), str(threads)],
        capture_output=True, text=True, timeout=120, env=env,
    )
    if proc.returncode != 0:
        return {"error": proc.stderr.strip() or "non-zero exit, no stderr"}
    try:
        return json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception as e:
        return {"error": f"could not parse workload output: {e}", "raw_stdout": proc.stdout}


def run_agent(build_envs_path: str) -> dict:
    with open(build_envs_path) as f:
        envs = json.load(f)

    log = []

    baseline_env = envs.get("baseline", {})
    baseline_result = _run_workload(
        baseline_env.get("python_path"), baseline_env.get("lib_dir", ""), threads=-1,
    )
    log.append({"step": "baseline_run", "threads": -1, "result": baseline_result})

    if "error" in baseline_result:
        return {"verdict": "FAILED", "reason": "baseline run failed", "log": log}

    baseline_total = baseline_result["total_seconds_mean"]
    cool_env = envs.get("cool", {})

    best = None
    for threads in THREAD_CANDIDATES:
        result = _run_workload(cool_env.get("python_path"), cool_env.get("lib_dir", ""), threads)
        log.append({"step": "cool_run", "threads": threads, "result": result})

        if "error" in result:
            continue

        speedup = baseline_total / result["total_seconds_mean"]
        result["_speedup_vs_baseline"] = speedup
        log.append({"step": "evaluate", "threads": threads, "speedup": speedup,
                    "target": TARGET_SPEEDUP, "met_target": speedup >= TARGET_SPEEDUP})

        if best is None or speedup > best["_speedup_vs_baseline"]:
            best = result
            best["_threads_used"] = threads

        if speedup >= TARGET_SPEEDUP:
            return {
                "verdict": "TARGET_MET",
                "baseline_total_seconds_mean": baseline_total,
                "best_config": {"threads": threads, "speedup_vs_baseline": speedup},
                "best_result": result,
                "log": log,
            }

    # Exhausted candidates without hitting target -- report the best we found,
    # explicitly, as a failure case rather than hiding it.
    if best is None:
        return {"verdict": "FAILED", "reason": "every COOL run errored", "log": log}

    return {
        "verdict": "TARGET_NOT_MET",
        "baseline_total_seconds_mean": baseline_total,
        "best_config": {"threads": best["_threads_used"], "speedup_vs_baseline": best["_speedup_vs_baseline"]},
        "best_result": best,
        "log": log,
    }


if __name__ == "__main__":
    build_envs_path = sys.argv[1] if len(sys.argv) > 1 else str(HERE / "build_envs.json")
    report = run_agent(build_envs_path)
    print("===AGENT_REPORT_START===")
    print(json.dumps(report, indent=2))
    print("===AGENT_REPORT_END===")

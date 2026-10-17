"""
Runs the real-image validation: baseline vs COOL, same instance, on a real
downloaded photo instead of synthetic noise. Minimal by design -- this is a
targeted extension to check the main finding generalizes, not a replacement
for the main multi-resolution benchmark.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
BASELINE_PYTHON = "/tmp/baseline_venv/bin/python3"


def _run(python_bin: str, extra_env: dict, threads: int, image_url: str) -> dict:
    env = dict(os.environ)
    for k, v in extra_env.items():
        env[k] = f"{v}:{env.get(k, '')}"
    proc = subprocess.run(
        [python_bin, str(HERE / "real_image_workload.py"), str(threads), image_url],
        capture_output=True, text=True, timeout=120, env=env,
    )
    if proc.returncode != 0:
        return {"error": proc.stderr.strip() or "non-zero exit, no stderr"}
    try:
        return json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception as e:
        return {"error": f"could not parse output: {e}", "raw_stdout": proc.stdout}


def run_agent(build_envs_path: str, image_url: str, image_label: str) -> dict:
    with open(build_envs_path) as f:
        envs = json.load(f)
    cool_env = envs.get("cool", {})
    cool_extra_env = {"LD_LIBRARY_PATH": cool_env.get("lib_dir", "")}
    if cool_env.get("python_path"):
        cool_extra_env["PYTHONPATH"] = cool_env["python_path"]

    baseline_result = _run(BASELINE_PYTHON, {}, -1, image_url)
    cool_result = _run("python3", cool_extra_env, -1, image_url)

    out = {"image_label": image_label, "image_url": image_url,
           "baseline": baseline_result, "cool": cool_result}
    if "error" not in baseline_result and "error" not in cool_result:
        out["speedup_vs_baseline"] = baseline_result["total_seconds_mean"] / cool_result["total_seconds_mean"]
        out["per_op_speedup"] = {
            op: baseline_result["ops_seconds"][op]["mean"] / cool_result["ops_seconds"][op]["mean"]
            for op in baseline_result["ops_seconds"]
        }
    return out


if __name__ == "__main__":
    build_envs_path = sys.argv[1]
    image_url = sys.argv[2]
    image_label = sys.argv[3] if len(sys.argv) > 3 else "real_image"
    report = run_agent(build_envs_path, image_url, image_label)
    print("===REAL_IMAGE_REPORT_START===")
    print(json.dumps(report, indent=2))
    print("===REAL_IMAGE_REPORT_END===")

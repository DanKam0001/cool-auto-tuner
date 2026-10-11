#!/bin/bash
set -x
mkdir -p /tmp/agent
cat <<'PYEOF' > /tmp/agent/workload.py
"""
Defines the benchmark workload: a fixed set of OpenCV operations run against
a fixed set of synthetic test images, timed identically regardless of which
OpenCV build (vanilla /install-4x vs COOL /install-cool) is active on
LD_LIBRARY_PATH / PYTHONPATH.

Kept deliberately simple and dependency-light (numpy + cv2 only) so it runs
unmodified under either build.
"""
import time
import numpy as np
import cv2

# Fixed seed so every run (baseline, COOL, every iteration) uses identical
# input data -- the only thing allowed to vary is which OpenCV build runs it.
_RNG = np.random.default_rng(seed=42)


def _make_test_images(n: int, size: tuple[int, int]) -> list[np.ndarray]:
    h, w = size
    return [_RNG.integers(0, 256, (h, w, 3), dtype=np.uint8) for _ in range(n)]


def _time_op(fn, *args, repeats: int, **kwargs) -> float:
    """Returns mean seconds per call over `repeats` runs, after one warmup call."""
    fn(*args, **kwargs)  # warmup, not timed
    start = time.perf_counter()
    for _ in range(repeats):
        fn(*args, **kwargs)
    return (time.perf_counter() - start) / repeats


def run_workload(image_size: tuple[int, int] = (1080, 1920), n_images: int = 20,
                  repeats: int = 10) -> dict:
    """
    Runs a fixed suite of common OpenCV ops and returns per-op mean latency
    (seconds) plus metadata about what was run, so results are comparable
    and reproducible across builds/instances.
    """
    images = _make_test_images(n_images, image_size)
    gray_images = [cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) for img in images]

    results = {}

    results["resize_half"] = _time_op(
        lambda: [cv2.resize(img, None, fx=0.5, fy=0.5, interpolation=cv2.INTER_LINEAR)
                 for img in images],
        repeats=repeats,
    )

    results["gaussian_blur_15"] = _time_op(
        lambda: [cv2.GaussianBlur(img, (15, 15), 0) for img in images],
        repeats=repeats,
    )

    results["canny_edge"] = _time_op(
        lambda: [cv2.Canny(g, 100, 200) for g in gray_images],
        repeats=repeats,
    )

    orb = cv2.ORB_create(nfeatures=500)
    results["orb_detect_compute"] = _time_op(
        lambda: [orb.detectAndCompute(g, None) for g in gray_images],
        repeats=repeats,
    )

    results["warp_affine"] = _time_op(
        lambda: [cv2.warpAffine(
            img,
            cv2.getRotationMatrix2D((img.shape[1] / 2, img.shape[0] / 2), 15, 1.0),
            (img.shape[1], img.shape[0]),
        ) for img in images],
        repeats=repeats,
    )

    return {
        "opencv_version": cv2.__version__,
        "opencv_build_path": cv2.__file__,
        "image_size": image_size,
        "n_images": n_images,
        "repeats": repeats,
        "ops_seconds_mean": results,
        "total_seconds_mean": sum(results.values()),
    }


if __name__ == "__main__":
    import json
    import sys

    threads = int(sys.argv[1]) if len(sys.argv) > 1 else -1
    if threads > 0:
        cv2.setNumThreads(threads)

    result = run_workload()
    result["cv2_num_threads_requested"] = threads
    result["cv2_num_threads_actual"] = cv2.getNumThreads()
    print(json.dumps(result))
PYEOF
cat <<'PYEOF' > /tmp/agent/discover_envs.py
"""
Run ON the Graviton instance (not locally -- cv2 bindings only exist there).

Scans the two parallel OpenCV installs shipped on the COOL AMI
(/install-4x = vanilla baseline, /install-cool = COOL-accelerated) for their
compiled Python bindings, and writes out the exact LD_LIBRARY_PATH /
PYTHONPATH each one needs so agent.py can launch workload.py as a clean
subprocess under either build without guessing paths.
"""
import json
import subprocess
from pathlib import Path

CANDIDATE_ROOTS = {
    "baseline": "/install-4x",
    "cool": "/install-cool",
}


def _find(root: str, pattern: str) -> list[str]:
    try:
        out = subprocess.run(
            ["find", root, "-iname", pattern],
            capture_output=True, text=True, timeout=30,
        )
        return [line for line in out.stdout.splitlines() if line.strip()]
    except Exception as e:
        return [f"ERROR: {e}"]


def discover() -> dict:
    envs = {}
    for label, root in CANDIDATE_ROOTS.items():
        if not Path(root).exists():
            envs[label] = {"error": f"{root} does not exist"}
            continue

        cv2_so = _find(root, "cv2*.so")
        cv2_dir = _find(root, "cv2")
        lib_dir = str(Path(root) / "lib")

        # The python bindings directory is the parent dir of the cv2*.so file
        # (or the cv2 package dir, if it's a package rather than a loose .so)
        py_path = None
        if cv2_so:
            py_path = str(Path(cv2_so[0]).parent)
        elif cv2_dir:
            # cv2_dir may be the package itself; python path is its parent
            py_path = str(Path(cv2_dir[0]).parent)

        envs[label] = {
            "root": root,
            "lib_dir": lib_dir,
            "cv2_so_matches": cv2_so,
            "cv2_dir_matches": cv2_dir,
            "python_path": py_path,
            "setup_vars_script": _find(root, "setup_vars_opencv4.sh"),
        }
    return envs


if __name__ == "__main__":
    result = discover()
    print("===DISCOVER_ENVS_START===")
    print(json.dumps(result, indent=2))
    print("===DISCOVER_ENVS_END===")
PYEOF
cat <<'PYEOF' > /tmp/agent/agent.py
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

The actual "agentic" loop, not a one-shot call:
  1. Run the fixed benchmark workload under the baseline venv.
  2. Run it under COOL at a candidate thread count.
  3. Evaluate: did COOL beat the target speedup? If not, try the next
     thread-count candidate -- each next action is chosen based on the
     previous measurement, not a fixed script.
  4. Stop when it hits the target, runs out of candidates, or every attempt
     errors, and report a verdict either way, including failure cases.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
BASELINE_PYTHON = "/tmp/baseline_venv/bin/python3"
TARGET_SPEEDUP = 1.15  # COOL must beat baseline by >=15% to "win" a config
THREAD_CANDIDATES = [-1, 1, 2, 4]  # -1 = let OpenCV pick its own default


def _run(python_bin: str, extra_env: dict, threads: int) -> dict:
    env = dict(os.environ)
    for k, v in extra_env.items():
        env[k] = f"{v}:{env.get(k, '')}"

    proc = subprocess.run(
        [python_bin, str(HERE / "workload.py"), str(threads)],
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

    baseline_result = _run(BASELINE_PYTHON, {}, threads=-1)
    log.append({"step": "baseline_run", "python": BASELINE_PYTHON, "threads": -1, "result": baseline_result})

    if "error" in baseline_result:
        return {"verdict": "FAILED", "reason": "baseline run failed", "log": log}

    baseline_total = baseline_result["total_seconds_mean"]

    cool_env = envs.get("cool", {})
    cool_extra_env = {"LD_LIBRARY_PATH": cool_env.get("lib_dir", "")}
    if cool_env.get("python_path"):
        cool_extra_env["PYTHONPATH"] = cool_env["python_path"]

    best = None
    for threads in THREAD_CANDIDATES:
        result = _run("python3", cool_extra_env, threads)
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
PYEOF
echo "===SETUP_START==="
pip install --break-system-packages -q numpy 2>&1 | tail -5
python3 -m venv /tmp/baseline_venv
/tmp/baseline_venv/bin/pip install -q numpy opencv-python-headless 2>&1 | tail -10
cd /tmp/agent
python3 discover_envs.py | tee /tmp/agent/discover_output.txt
python3 -c "import json,re; txt=open(\"/tmp/agent/discover_output.txt\").read(); start=txt.index(\"{\"); end=txt.rindex(\"}\")+1; json.dump(json.loads(txt[start:end]), open(\"/tmp/agent/build_envs.json\",\"w\"))"
echo "===SETUP_END==="
python3 agent.py /tmp/agent/build_envs.json

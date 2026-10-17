cat <<'PYEOF' > /tmp/agent/workload.py
"""
Defines the benchmark workload: a fixed set of OpenCV operations run against
a fixed set of synthetic test images, timed identically regardless of which
OpenCV build (vanilla pip baseline vs COOL) is active.
"""
import statistics
import time
import numpy as np
import cv2

# Fixed seed so every run (baseline, COOL, every iteration) uses identical
# input data -- the only thing allowed to vary is which OpenCV build runs it.
_RNG = np.random.default_rng(seed=42)

# Shared single source of truth for resolution tiers, so agent.py and
# workload.py always agree on what e.g. "1080p" means.
RESOLUTIONS = {
    "480p": (480, 854),
    "1080p": (1080, 1920),
    "4k": (2160, 3840),
}

# Heavier resolutions get fewer repeats so a single run stays a reasonable
# length -- still enough repeats to report a meaningful standard deviation.
REPEATS_BY_RESOLUTION = {
    "480p": 10,
    "1080p": 10,
    "4k": 4,
}


def _make_test_images(n: int, size: tuple[int, int]) -> list[np.ndarray]:
    h, w = size
    return [_RNG.integers(0, 256, (h, w, 3), dtype=np.uint8) for _ in range(n)]


def _time_op(fn, *args, repeats: int, **kwargs) -> dict:
    """Returns {mean, std, n} seconds per call over `repeats` timed runs, after
    one warmup call (not timed, not counted)."""
    fn(*args, **kwargs)  # warmup
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        fn(*args, **kwargs)
        samples.append(time.perf_counter() - start)
    return {
        "mean": statistics.mean(samples),
        "std": statistics.stdev(samples) if len(samples) > 1 else 0.0,
        "n": len(samples),
    }


def run_workload(image_size: tuple[int, int], n_images: int, repeats: int) -> dict:
    """
    Runs a fixed suite of common OpenCV ops and returns per-op timing stats
    (mean + standard deviation, not just a single number) plus metadata
    about what was run, so results are comparable, reproducible, and
    honestly report their own noise across builds/instances/resolutions.
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

    total_mean = sum(r["mean"] for r in results.values())
    # Standard deviations of independent sums add in quadrature.
    total_std = sum(r["std"] ** 2 for r in results.values()) ** 0.5

    return {
        "opencv_version": cv2.__version__,
        "opencv_build_path": cv2.__file__,
        "image_size": image_size,
        "n_images": n_images,
        "repeats": repeats,
        "ops_seconds": results,
        "total_seconds_mean": total_mean,
        "total_seconds_std": total_std,
    }


if __name__ == "__main__":
    import json
    import sys

    threads = int(sys.argv[1]) if len(sys.argv) > 1 else -1
    resolution = sys.argv[2] if len(sys.argv) > 2 else "1080p"

    if threads > 0:
        cv2.setNumThreads(threads)

    size = RESOLUTIONS[resolution]
    repeats = REPEATS_BY_RESOLUTION[resolution]

    result = run_workload(image_size=size, n_images=20, repeats=repeats)
    result["resolution_label"] = resolution
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
cat <<'PYEOF' > /tmp/agent/real_image_workload.py
"""
Extension of the core benchmark: same five ops, same timing methodology, but
run against a real downloaded photo instead of synthetic noise -- to check
whether the speedup holds on realistic, content-rich images (busy edges,
real textures), not just the controlled synthetic test set used for the
main benchmark. Run on the SAME AWS Graviton instance for both builds, same
as the main methodology -- comparing against a local run on different
hardware would be meaningless.
"""
import statistics
import sys
import time
import urllib.request
import numpy as np
import cv2

from workload import _time_op  # reuse the exact same timing helper


def run_real_image_workload(image_url: str, n_copies: int, repeats: int) -> dict:
    data = urllib.request.urlopen(image_url, timeout=30).read()
    arr = np.frombuffer(data, dtype=np.uint8)
    base_img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    base_img = cv2.resize(base_img, (1920, 1080))

    images = [base_img.copy() for _ in range(n_copies)]
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

    total_mean = sum(r["mean"] for r in results.values())
    total_std = sum(r["std"] ** 2 for r in results.values()) ** 0.5

    return {
        "opencv_version": cv2.__version__,
        "image_url": image_url,
        "image_size": [1920, 1080],
        "n_images": n_copies,
        "repeats": repeats,
        "ops_seconds": results,
        "total_seconds_mean": total_mean,
        "total_seconds_std": total_std,
    }


if __name__ == "__main__":
    import json
    threads = int(sys.argv[1]) if len(sys.argv) > 1 else -1
    image_url = sys.argv[2]

    if threads > 0:
        cv2.setNumThreads(threads)

    result = run_real_image_workload(image_url, n_copies=20, repeats=10)
    result["cv2_num_threads_requested"] = threads
    result["cv2_num_threads_actual"] = cv2.getNumThreads()
    print(json.dumps(result))
PYEOF
cat <<'PYEOF' > /tmp/agent/real_image_agent.py
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
PYEOF
echo "===SETUP_START==="
pip install --break-system-packages -q numpy 2>&1 | tail -5
python3 -m venv /tmp/baseline_venv
/tmp/baseline_venv/bin/pip install -q numpy opencv-python-headless 2>&1 | tail -10
cd /tmp/agent
python3 discover_envs.py | tee /tmp/agent/discover_output.txt
python3 -c "import json,re; txt=open(\"/tmp/agent/discover_output.txt\").read(); start=txt.index(\"{\"); end=txt.rindex(\"}\")+1; json.dump(json.loads(txt[start:end]), open(\"/tmp/agent/build_envs.json\",\"w\"))"
echo "===SETUP_END==="
timeout 200 python3 real_image_agent.py /tmp/agent/build_envs.json "https://pixabay.com/get/gd1cc3898cd734deec58d7abc94d50e033eaea2cbaec03868053462719d0755a4443be31c1477e89ddff3d3f7e097be5e3d93e0f3ee1e6a8586241d6f42cbb771_1280.jpg" "traffic"
timeout 200 python3 real_image_agent.py /tmp/agent/build_envs.json "https://pixabay.com/get/ge6ff4d360e7f905c4ad1d16854be610e5692dcfd068996149fec88002bc6f2ffd1bf87cf8ff15470d83d5d5c4a21c0ba7a86bfd649f90f1eff980ba3be578b5a_1280.jpg" "factory"
timeout 200 python3 real_image_agent.py /tmp/agent/build_envs.json "https://pixabay.com/get/gd5946282e23ee1ce4e96cffff55e5406fd2853cfaa8c15b3c8494e3a2d885494f89e789e6375bdafe631c3dc4148be8718d9d5bfe352e8226a3f466934d25c65_1280.jpg" "aerial"
echo "===INSTANCE_SELF_SHUTDOWN==="
shutdown -h now

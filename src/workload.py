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

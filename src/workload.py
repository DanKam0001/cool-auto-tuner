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

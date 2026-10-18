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
    req = urllib.request.Request(
        image_url,
        headers={"User-Agent": "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 "
                                "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"},
    )
    data = urllib.request.urlopen(req, timeout=30).read()
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

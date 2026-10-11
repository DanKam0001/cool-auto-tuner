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

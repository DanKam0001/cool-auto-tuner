# COOL Auto-Tuner

Built for the [OpenCV AI Competition 2026, powered by AWS](https://opencv26.devpost.com/).

AWS Marketplace sells [Cloud-Optimized OpenCV (COOL)](https://opencv.org/cool/), a build of
OpenCV compiled for AWS Graviton and sold as faster than a standard pip install. COOL
Auto-Tuner is an agent that checks that claim on real AWS hardware against a real
OpenCV 5 baseline, and reports what it finds, including when COOL doesn't help.

## Headline results

| Workload | COOL vs. pip OpenCV 5.0.0 |
|---|---|
| Synthetic benchmark, 25 runs, 480p/1080p/4K, 2 instance sizes | **~1.36x faster** (range 1.29x-1.46x) |
| 9 real photos (aerial, medical, retail, sports, traffic, factory, agriculture, plain, forest) | **~1.06x on average, slower on 5 of 9** |
| Thread sweep (1/2/4 threads, matched baseline per thread count) | faster at every thread count; ~8-9% single-threaded, ~30-36% at 2+ |

Per operation, the pattern holds on every real image: blur and Canny are always faster on
COOL, resize (~20%) and warpAffine (~42%) are always slower, and ORB feature detection
decides the overall result depending on how feature-rich the image is. Full numbers,
method and caveats are in [`docs/REPORT.md`](docs/REPORT.md).

## How the agent works

1. Launches a Graviton `c8g.large` from the COOL Marketplace AMI with a user-data script
   (no SSH keys, no open ports).
2. Builds a genuinely vanilla baseline: an isolated venv with the current
   `opencv-python-headless` from PyPI (5.0.0 for every run reported here).
3. Discovers COOL's prebuilt Python bindings on the AMI and injects the right
   `LD_LIBRARY_PATH`/`PYTHONPATH` at runtime ([`src/discover_envs.py`](src/discover_envs.py)).
4. Runs the same five-op workload (resize, Gaussian blur, Canny, ORB, warpAffine) under
   both builds ([`src/workload.py`](src/workload.py)).
5. Compares against a target speedup. If COOL misses it, the agent tries the next thread
   configuration, re-measuring the baseline at the same thread count, until it hits the
   target or runs out of candidates ([`src/agent.py`](src/agent.py)).
6. Writes a per-resolution verdict and decision log, then the instance shuts itself down.

[`src/real_image_agent.py`](src/real_image_agent.py) runs the same comparison on real
photos downloaded onto the instance.

## Reproducing

Accept the COOL Marketplace subscription once in the AWS console, then:

```bash
infra/launch.sh infra/run-userdata.sh c8g.large
```

[`infra/launch.sh`](infra/launch.sh) launches the instance from the COOL AMI
(`ami-033e481a24f94c8cb` in `us-east-1`), waits for it to finish and terminate itself,
terminates it anyway after `MAX_MINUTES` as a backstop, and saves the console output to
`benchmarks/raw/`. The user-data scripts:

- `run-userdata.sh`: standard run, 1.25x target, 480p/1080p/4K
- `run-userdata-stress.sh`: 1.6x target, forces the full thread-count sweep
- `run-userdata-realimg.sh` / `run-userdata-realimg2.sh`: real-image validation (the
  Pixabay download URLs in these scripts were temporary CDN links and will have expired;
  swap in your own image URLs)

A standard run takes about 10-15 minutes on a `c8g.large`. The IAM permissions used
are in [`infra/iam-policy.json`](infra/iam-policy.json). Raw results from every run are
in [`benchmarks/`](benchmarks/).

## Repo layout

- `src/`: the agent and benchmark workloads
- `infra/`: EC2 user-data scripts and the IAM policy
- `benchmarks/`: raw console output and parsed results for every run
- `docs/`: technical report, video script, and the HTML scenes used in the demo video

## License

[MIT](LICENSE)

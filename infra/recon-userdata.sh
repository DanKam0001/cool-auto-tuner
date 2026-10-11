#!/bin/bash
echo "===RECON_START==="
echo "--- OS ---"
cat /etc/os-release
echo "--- arch ---"
uname -m
echo "--- python3 ---"
which python3 && python3 --version
echo "--- pip packages (cv2/opencv related) ---"
python3 -m pip list 2>/dev/null | grep -i -E "opencv|cv2|cool" || echo "none found via pip list"
echo "--- cv2 import check ---"
python3 -c "import cv2; print('cv2 version:', cv2.__version__); print('cv2 file:', cv2.__file__)" 2>&1
echo "--- look for COOL-specific install dirs ---"
find / -maxdepth 4 -iname "*cool*" 2>/dev/null
find / -maxdepth 4 -iname "*opencv*" 2>/dev/null
echo "--- /opt and /usr/local contents ---"
ls -la /opt 2>/dev/null
ls -la /usr/local 2>/dev/null
echo "===RECON_END==="

"""Load LiDO's host CUDA libraries globally before Python CUDA frameworks start."""

import ctypes
import os
import warnings


if os.environ.get("LIDO_AGENT_GPU"):
    _cuda_library_dir = "/usr/lib/x86_64-linux-gnu"
    for _cuda_library in (
        "libcuda.so.1",
        "libnvidia-ptxjitcompiler.so.1",
        "libnvidia-nvvm.so.4",
    ):
        try:
            ctypes.CDLL(
                os.path.join(_cuda_library_dir, _cuda_library),
                mode=ctypes.RTLD_GLOBAL,
            )
        except OSError as _error:
            warnings.warn(
                f"LiDO GPU session could not preload {_cuda_library}: {_error}",
                RuntimeWarning,
                stacklevel=2,
            )

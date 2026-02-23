"""
Eye blink detection via webcam  ·  MediaPipe Face Landmarker (Tasks API) + EAR.

MediaPipe 0.10+ removed mp.solutions — this module uses the Tasks API instead:
    mp.tasks.python.vision.FaceLandmarker  (VIDEO running mode)

Eye Aspect Ratio (EAR):
    EAR = (|p2-p6| + |p3-p5|) / (2 |p1-p4|)
    Open eye  → EAR ≈ 0.25–0.35
    Blink     → EAR < 0.20

Snapshots
---------
  _frame_open   : face crop saved every ~2 s while eyes are clearly open
  _frame_closed : face crop at minimum EAR frame during each detected blink

Runs in a daemon background thread.  All public methods are thread-safe.
"""

from __future__ import annotations

import base64
import os
import threading
import time
import urllib.request
from collections import deque

# Tell OpenCV not to request camera authorization at runtime (can't show dialog
# from a background thread on macOS).  The user must have already granted
# camera access to this Python binary via System Settings → Privacy → Camera.
os.environ.setdefault("OPENCV_AVFOUNDATION_SKIP_AUTH", "1")

import numpy as np

try:
    import cv2                                               # type: ignore
    import mediapipe as mp                                   # type: ignore
    from mediapipe.tasks.python import vision as mp_vision   # type: ignore
    from mediapipe.tasks.python.core.base_options import BaseOptions  # type: ignore
    _DEPS_OK = True
except ImportError:
    _DEPS_OK = False

# ── EAR parameters ────────────────────────────────────────────────────────────
EAR_THRESH       = 0.20   # fallback only; replaced by adaptive threshold at runtime
EAR_OPEN_MIN     = 0.23   # above → eye clearly open (lower than avg because we use min(L,R))
MIN_FRAMES       = 1      # 1 processed frame at ~15 fps ≈ 67 ms — catches fast blinks
_OPEN_SAVE_EVERY = 15     # save open snapshot every N processed frames (~1 s @ 15 fps)

# MediaPipe Face Landmarker landmark indices (same 478-point model)
# Six points per eye: [outer, upper-a, upper-b, inner, lower-b, lower-a]
_LEFT_EYE  = [362, 385, 387, 263, 373, 380]
_RIGHT_EYE = [ 33, 160, 158, 133, 153, 144]

# Physiological inter-blink interval bounds
_IBI_MIN = 0.15
_IBI_MAX = 15.0

# Cached model path
_MODEL_PATH = os.path.expanduser("~/.cache/mediapipe/face_landmarker.task")
_MODEL_URL  = (
    "https://storage.googleapis.com/mediapipe-models/"
    "face_landmarker/face_landmarker/float16/1/face_landmarker.task"
)


def _ensure_model() -> bool:
    """Download the face landmarker model if not already cached."""
    if os.path.exists(_MODEL_PATH):
        return True
    try:
        os.makedirs(os.path.dirname(_MODEL_PATH), exist_ok=True)
        print("[blink] downloading face landmarker model…", flush=True)
        urllib.request.urlretrieve(_MODEL_URL, _MODEL_PATH)
        print("[blink] model ready.", flush=True)
        return True
    except Exception as exc:
        print(f"[blink] model download failed: {exc}", flush=True)
        return False


class BlinkDetector:
    """Thread-safe eye blink monitor using webcam + MediaPipe Face Landmarker."""

    def __init__(self, camera_index: int = 0) -> None:
        self._cam_idx      = camera_index
        self._lock         = threading.Lock()
        self._running      = False
        self._status       = "idle"
        self._ear_val      = 0.0
        self._frame_open:   np.ndarray | None = None
        self._frame_closed: np.ndarray | None = None
        self._blinks: deque[float] = deque(maxlen=1000)
        self._ibis:   deque[float] = deque(maxlen=300)

    # ── public API ─────────────────────────────────────────────────────────────

    def start(self) -> None:
        if not _DEPS_OK:
            self._status = "unavailable — pip install opencv-python mediapipe"
            return
        if self._running:
            return
        self._running = True
        threading.Thread(target=self._loop, daemon=True).start()

    def stop(self) -> None:
        self._running = False

    def get_stats(self, window_s: float = 60.0) -> dict:
        now = time.time()
        with self._lock:
            recent = [t for t in self._blinks if now - t <= window_s]
            ear    = self._ear_val

        rate = len(recent) / (window_s / 60.0)
        window_ibis = [
            t2 - t1 for t1, t2 in zip(recent, recent[1:])
            if _IBI_MIN <= (t2 - t1) <= _IBI_MAX
        ]
        brv = float(np.std(window_ibis)) if len(window_ibis) >= 3 else 0.0
        return dict(
            rate=round(rate, 1),
            brv=round(brv, 3),
            n_blinks=len(recent),
            ear=round(ear, 3),
            status=self._status,
        )

    def get_recent_ibis(self, n: int = 60) -> list[float]:
        with self._lock:
            return list(self._ibis)[-n:]

    def get_preview_images(self) -> tuple[str | None, str | None]:
        """Return (open_img, closed_img) as base64 JPEG data URIs or None."""
        with self._lock:
            f_open   = self._frame_open
            f_closed = self._frame_closed
        return self._encode(f_open), self._encode(f_closed)

    @property
    def available(self) -> bool:
        return _DEPS_OK

    # ── helpers ────────────────────────────────────────────────────────────────

    @staticmethod
    def _encode(frame: np.ndarray | None) -> str | None:
        if frame is None or frame.size == 0:
            return None
        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
        if not ok:
            return None
        return "data:image/jpeg;base64," + base64.b64encode(buf.tobytes()).decode()

    @staticmethod
    def _compute_ear(landmarks, indices: list[int], w: int, h: int) -> float:
        pts = np.array(
            [(landmarks[i].x * w, landmarks[i].y * h) for i in indices],
            dtype=float,
        )
        A = np.linalg.norm(pts[1] - pts[5])
        B = np.linalg.norm(pts[2] - pts[4])
        C = np.linalg.norm(pts[0] - pts[3])
        return float((A + B) / (2.0 * C)) if C > 1e-6 else 0.30

    @staticmethod
    def _eyes_crop(frame: np.ndarray, landmarks, w: int, h: int,
                   pad_x: int = 24, pad_y_top: int = 28, pad_y_bot: int = 14
                   ) -> np.ndarray:
        """Crop both eyes (+ eyebrows) from the frame."""
        xs = [landmarks[i].x * w for i in _LEFT_EYE + _RIGHT_EYE]
        ys = [landmarks[i].y * h for i in _LEFT_EYE + _RIGHT_EYE]
        x1 = max(0, int(min(xs)) - pad_x)
        y1 = max(0, int(min(ys)) - pad_y_top)
        x2 = min(w, int(max(xs)) + pad_x)
        y2 = min(h, int(max(ys)) + pad_y_bot)
        crop = frame[y1:y2, x1:x2]
        return crop if crop.size > 0 else frame

    # ── background loop ────────────────────────────────────────────────────────

    def _loop(self) -> None:
        self._status = "loading model…"
        if not _ensure_model():
            self._status  = "model download failed — check internet connection"
            self._running = False
            return

        cap = cv2.VideoCapture(self._cam_idx)
        if not cap.isOpened():
            self._status  = (
                "camera unavailable — grant access to Python in "
                "System Settings → Privacy & Security → Camera"
            )
            self._running = False
            return

        options = mp_vision.FaceLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=_MODEL_PATH),
            running_mode=mp_vision.RunningMode.VIDEO,
            num_faces=1,
            min_face_detection_confidence=0.5,
            min_face_presence_confidence=0.5,
            min_tracking_confidence=0.5,
        )

        self._status = "running"
        consec            = 0
        in_blink          = False
        min_ear_val       = 1.0
        min_ear_frame: np.ndarray | None = None
        open_tick         = 0
        frame_n           = 0

        # Fix 4: 2-sample EAR smoother — suppresses single-frame landmark jitter
        ear_smooth_buf: deque[float] = deque(maxlen=2)

        # Fix 2: adaptive threshold — warm up from open-eye EAR baseline
        ear_baseline_buf: deque[float] = deque(maxlen=60)  # ~4 s at 15 fps
        ear_thresh = EAR_THRESH  # starts at fixed fallback, auto-calibrates in ~4 s

        with mp_vision.FaceLandmarker.create_from_options(options) as landmarker:
            while self._running:
                ok, frame = cap.read()
                if not ok:
                    time.sleep(0.033)
                    continue

                frame_n += 1
                if frame_n % 2 != 0:   # fix 5: every 2nd frame (~15 fps effective)
                    continue

                h, w      = frame.shape[:2]
                timestamp = int(time.time() * 1000)
                rgb       = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                mp_img    = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

                try:
                    result = landmarker.detect_for_video(mp_img, timestamp)
                except Exception:
                    continue

                if not result.face_landmarks:
                    with self._lock:
                        self._ear_val = 0.0
                    continue

                lm        = result.face_landmarks[0]
                left_ear  = self._compute_ear(lm, _LEFT_EYE,  w, h)
                right_ear = self._compute_ear(lm, _RIGHT_EYE, w, h)

                # Fix 3: min(L, R) — catches whichever eye closes first/more
                ear_raw = min(left_ear, right_ear)

                # Fix 4: smooth over last 2 samples to suppress landmark jitter
                ear_smooth_buf.append(ear_raw)
                ear = float(np.mean(ear_smooth_buf))

                with self._lock:
                    self._ear_val = ear

                # Fix 2: collect open-eye baseline and update adaptive threshold
                if ear > EAR_OPEN_MIN:
                    ear_baseline_buf.append(ear)
                    if len(ear_baseline_buf) >= 10:
                        ear_thresh = max(0.15, float(np.mean(ear_baseline_buf)) * 0.75)

                # ── open-eye snapshot every ~1 s ──────────────────────────────
                if ear > EAR_OPEN_MIN:
                    open_tick += 1
                    if open_tick >= _OPEN_SAVE_EVERY:
                        crop = self._eyes_crop(frame, lm, w, h)
                        with self._lock:
                            self._frame_open = crop.copy()
                        open_tick = 0
                else:
                    open_tick = 0

                # ── blink detection (uses adaptive threshold) ─────────────────
                if ear < ear_thresh:
                    consec   += 1
                    in_blink  = True
                    if ear < min_ear_val:
                        min_ear_val   = ear
                        min_ear_frame = frame.copy()
                else:
                    if in_blink and consec >= MIN_FRAMES:
                        now = time.time()
                        if min_ear_frame is not None:
                            crop = self._eyes_crop(min_ear_frame, lm, w, h)
                            with self._lock:
                                self._frame_closed = crop
                        with self._lock:
                            if self._blinks:
                                ibi = now - self._blinks[-1]
                                if _IBI_MIN <= ibi <= _IBI_MAX:
                                    self._ibis.append(ibi)
                            self._blinks.append(now)
                    consec        = 0
                    in_blink      = False
                    min_ear_val   = 1.0
                    min_ear_frame = None

        cap.release()
        self._status = "stopped"

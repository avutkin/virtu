from __future__ import annotations

import asyncio
import os
from datetime import datetime, timezone
from bleak import BleakScanner, BleakClient

# --- UUIDs ---
PMD_SERVICE = "FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8"
PMD_CONTROL = "FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8"
PMD_DATA    = "FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8"
HR_MEAS     = "00002A37-0000-1000-8000-00805F9B34FB"

# --- PMD commands ---
CMD_ECG_START = bytearray([0x02, 0x00, 0x00, 0x01, 0x82, 0x00, 0x01, 0x01, 0x0E, 0x00])
CMD_ACC_START = bytearray([0x02, 0x02, 0x00, 0x01, 0xC8, 0x00, 0x01, 0x01, 0x10, 0x00, 0x02, 0x01, 0x08, 0x00])
CMD_ECG_STOP  = bytearray([0x01, 0x00])
CMD_ACC_STOP  = bytearray([0x01, 0x02])

# PMD data frame type discriminator (first byte)
FRAME_ECG = 0x00
FRAME_ACC = 0x02


class PolarH10:
    def __init__(self, device_name: str = "Polar H10"):
        self.device_name = device_name
        self._client: BleakClient | None = None
        self._device_label: str = device_name

        self.ecg: list[dict] = []
        self.accelerometer: list[dict] = []
        self.pulse: list[dict] = []

    # ------------------------------------------------------------------
    # Connection
    # ------------------------------------------------------------------

    _ADDR_CACHE = os.path.expanduser("~/.justbreathe_h10_addr")

    async def connect(self, timeout: float = 20.0,
                      device_address: str | None = None) -> None:
        # --- Direct connect to a known address (skips scanning entirely) ---
        if device_address:
            print(f"Connecting directly to {device_address}…")
            try:
                client = BleakClient(device_address,
                                     disconnected_callback=self._on_disconnect)
                await client.connect(timeout=10.0)
                self._client = client
                self._device_label = device_address
                print(f"Connected to {device_address}.")
                return
            except Exception as exc:
                raise RuntimeError(
                    f"Direct connect to {device_address} failed: {exc}"
                ) from exc

        device = None

        # --- Fast path: try cached address first ---
        if os.path.exists(self._ADDR_CACHE):
            cached = open(self._ADDR_CACHE).read().strip()
            if cached:
                print(f"Trying cached address: {cached}")
                try:
                    client = BleakClient(cached,
                                        disconnected_callback=self._on_disconnect)
                    await client.connect(timeout=10.0)
                    self._client = client
                    self._device_label = self.device_name
                    print(f"Connected via cached address ({cached}).")
                    return
                except Exception as exc:
                    print(f"Cached address failed ({exc}), falling back to scan.")

        # --- Primary scan: filter by name ---
        print(f"Scanning for '{self.device_name}' (filter scan, {timeout:.0f}s)…")
        try:
            device = await BleakScanner.find_device_by_filter(
                lambda d, _: d.name and self.device_name in d.name,
                timeout=timeout,
            )
        except Exception as exc:
            print(f"Filter scan error: {exc}")

        # --- Fallback: full discovery + log everything visible ---
        if device is None:
            print("Filter scan found nothing. Running full BLE discovery (10 s)…")
            try:
                found = await BleakScanner.discover(timeout=10.0)
                if found:
                    print(f"Discovered {len(found)} device(s):")
                    for d in sorted(found, key=lambda x: x.name or ""):
                        print(f"  {d.address}  name={d.name!r}  rssi={d.rssi}")
                    # pick any device whose name contains our target
                    for d in found:
                        if d.name and self.device_name in d.name:
                            device = d
                            break
                else:
                    print("Full discovery returned zero devices — "
                          "check macOS Bluetooth permission for Terminal/Python.")
            except Exception as exc:
                print(f"Full discovery error: {exc}")

        if device is None:
            raise RuntimeError(
                f"Device '{self.device_name}' not found after filter scan and "
                "full discovery. Check that: (1) H10 is powered on and in range, "
                "(2) macOS Bluetooth is enabled, (3) Terminal/Python has Bluetooth "
                "permission in System Settings → Privacy & Security → Bluetooth."
            )

        self._device_label = device.name or self.device_name
        print(f"Found: {self._device_label} ({device.address})")

        self._client = BleakClient(device, disconnected_callback=self._on_disconnect)
        await self._client.connect()
        print("Connected.")

        # Cache the address for fast reconnection next time
        try:
            with open(self._ADDR_CACHE, "w") as f:
                f.write(str(device.address))
        except OSError:
            pass

    async def disconnect(self) -> None:
        if self._client and self._client.is_connected:
            await self._client.disconnect()

    def _on_disconnect(self, _client: BleakClient) -> None:
        print("Device disconnected.")

    # ------------------------------------------------------------------
    # Streaming
    # ------------------------------------------------------------------

    async def start_streams(self) -> None:
        c = self._client
        # Heart rate via standard GATT — supported by most BLE HR monitors
        try:
            await c.start_notify(HR_MEAS, self._hr_handler)
        except Exception as exc:
            print(f"HR notification unavailable: {exc}")

        # ECG + ACC via Polar PMD — Polar H10 / OH1 / Verity Sense only
        try:
            await c.start_notify(PMD_DATA, self._pmd_handler)
            await c.write_gatt_char(PMD_CONTROL, CMD_ECG_START, response=True)
            await c.write_gatt_char(PMD_CONTROL, CMD_ACC_START, response=True)
            print("Streaming ECG, accelerometer, and pulse.")
        except Exception as exc:
            print(f"Polar PMD unavailable — HR-only mode ({exc})")

    async def stop_streams(self) -> None:
        c = self._client
        try:
            await c.write_gatt_char(PMD_CONTROL, CMD_ECG_STOP, response=True)
            await c.write_gatt_char(PMD_CONTROL, CMD_ACC_STOP, response=True)
            await c.stop_notify(PMD_DATA)
            await c.stop_notify(HR_MEAS)
        except Exception:
            pass  # best-effort on teardown

    # ------------------------------------------------------------------
    # Notification handlers
    # ------------------------------------------------------------------

    def _hr_handler(self, _char, data: bytearray) -> None:
        flags = data[0]
        hr_format_16bit = flags & 0x01
        bpm = int.from_bytes(data[1:3], "little") if hr_format_16bit else data[1]

        rr_intervals: list[int] = []
        offset = 3 if hr_format_16bit else 2
        # RR intervals are present when bit 4 of flags is set
        if flags & 0x10:
            while offset + 1 < len(data):
                rr_raw = int.from_bytes(data[offset:offset + 2], "little")
                rr_intervals.append(round(rr_raw * 1000 / 1024))  # convert to ms
                offset += 2

        self.pulse.append({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "bpm": bpm,
            "rr_intervals_ms": rr_intervals,
        })

    def _pmd_handler(self, _char, data: bytearray) -> None:
        if len(data) < 10:
            return
        frame_type = data[0]
        if frame_type == FRAME_ECG:
            self._parse_ecg(data)
        elif frame_type == FRAME_ACC:
            self._parse_acc(data)

    # ------------------------------------------------------------------
    # Parsers
    # ------------------------------------------------------------------

    def _parse_ecg(self, data: bytearray) -> None:
        timestamp_ns = int.from_bytes(data[1:9], "little")
        samples: list[int] = []
        offset = 10
        while offset + 3 <= len(data):
            sample = int.from_bytes(data[offset:offset + 3], "little", signed=True)
            samples.append(sample)
            offset += 3
        if samples:
            self.ecg.append({"timestamp_ns": timestamp_ns, "samples_uV": samples})

    def _parse_acc(self, data: bytearray) -> None:
        timestamp_ns = int.from_bytes(data[1:9], "little")
        offset = 10
        while offset + 6 <= len(data):
            x = int.from_bytes(data[offset:offset + 2], "little", signed=True)
            y = int.from_bytes(data[offset + 2:offset + 4], "little", signed=True)
            z = int.from_bytes(data[offset + 4:offset + 6], "little", signed=True)
            self.accelerometer.append({
                "timestamp_ns": timestamp_ns,
                "x_mG": x,
                "y_mG": y,
                "z_mG": z,
            })
            offset += 6

    # ------------------------------------------------------------------
    # Data export
    # ------------------------------------------------------------------

    def get_session_data(self, session_start: str, duration_seconds: int) -> dict:
        return {
            "session_start": session_start,
            "device": self._device_label,
            "duration_seconds": duration_seconds,
            "ecg": self.ecg,
            "accelerometer": self.accelerometer,
            "pulse": self.pulse,
        }

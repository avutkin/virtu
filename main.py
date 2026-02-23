import argparse
import asyncio
from datetime import datetime, timezone

import db
from polar import PolarH10

DB_PATH = "just-breathe.db"


async def run(duration: int) -> None:
    started_at = datetime.now(timezone.utc).isoformat()
    sensor = PolarH10("Polar H10")

    conn = db.init_db(DB_PATH)

    try:
        await sensor.connect()
        session_id = db.insert_session(conn, sensor._device_label, started_at)
        await sensor.start_streams()
        print(f"Recording for {duration} seconds... Press Ctrl+C to stop early.")
        await asyncio.sleep(duration)
    except KeyboardInterrupt:
        print("\nStopped by user.")
    finally:
        await sensor.stop_streams()
        await sensor.disconnect()

    ended_at = datetime.now(timezone.utc).isoformat()
    db.update_session_end(conn, session_id, ended_at, duration)

    ecg_count  = db.insert_ecg_batch(conn, session_id, sensor.ecg)
    acc_count  = db.insert_acc_batch(conn, session_id, sensor.accelerometer)
    pulse_count = db.insert_pulse_batch(conn, session_id, sensor.pulse)

    conn.close()

    print(f"\nSaved to {DB_PATH}  (session id={session_id})")
    print(f"  ECG samples  : {ecg_count}")
    print(f"  ACC samples  : {acc_count}")
    print(f"  Pulse beats  : {pulse_count}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Record data from Polar H10")
    parser.add_argument(
        "--duration",
        type=int,
        default=60,
        help="Recording duration in seconds (default: 60)",
    )
    args = parser.parse_args()
    asyncio.run(run(args.duration))


if __name__ == "__main__":
    main()

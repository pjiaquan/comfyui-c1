# /// script
# dependencies = [
#     "requests",
#     "watchdog",
# ]
# ///

import os
import sys
import time
from pathlib import Path
from typing import Optional

import requests
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

# =========================
# Configuration
# =========================
WATCH_DIRECTORY = os.environ.get("WATCH_DIRECTORY", "/opt/ComfyUI/output")
BOT_TOKEN = os.environ.get("MyD3_TELEGRAM_BOT_TOKEN")
CHAT_ID = os.environ.get("MyD3_TELEGRAM_CHAT_ID")

# 遞迴監看子資料夾
RECURSIVE_WATCH = True

# 上傳成功後是否刪檔
DELETE_AFTER_SEND = False

# 檔案穩定檢查設定
FILE_STABLE_CHECK_INTERVAL = 1.0   # 秒
FILE_STABLE_ROUNDS = 2             # 連續幾次檔案大小相同才算寫完
MAX_WAIT_FOR_STABLE = 60           # 最長等待秒數

# 允許的副檔名
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif"}
VIDEO_EXTENSIONS = {".mp4"}
ALLOWED_EXTENSIONS = IMAGE_EXTENSIONS | VIDEO_EXTENSIONS

# HTTP
REQUEST_TIMEOUT = 120
MAX_RETRIES = 3
RETRY_DELAY = 3


# =========================
# Utilities
# =========================
def log(message: str) -> None:
    print(message, flush=True)


def validate_env() -> None:
    if not BOT_TOKEN or not CHAT_ID:
        log("Error: Missing environment variables.")
        log("Required:")
        log("  - MyD3_TELEGRAM_BOT_TOKEN")
        log("  - MyD3_TELEGRAM_CHAT_ID")
        sys.exit(1)


def is_supported_file(file_path: Path) -> bool:
    return file_path.is_file() and file_path.suffix.lower() in ALLOWED_EXTENSIONS


def wait_until_file_is_stable(file_path: Path) -> bool:
    """
    等待檔案寫入完成。
    判斷方式：檔案大小連續幾次都沒變。
    """
    stable_count = 0
    last_size: Optional[int] = None
    start_time = time.time()

    while time.time() - start_time < MAX_WAIT_FOR_STABLE:
        if not file_path.exists():
            return False

        try:
            current_size = file_path.stat().st_size
        except FileNotFoundError:
            return False

        if current_size > 0 and current_size == last_size:
            stable_count += 1
            if stable_count >= FILE_STABLE_ROUNDS:
                return True
        else:
            stable_count = 0
            last_size = current_size

        time.sleep(FILE_STABLE_CHECK_INTERVAL)

    log(f"Timeout waiting for file to stabilize: {file_path}")
    return False


def build_caption(file_path: Path) -> str:
    """
    保留相對路徑，子資料夾也看得出來。
    """
    try:
        relative_path = file_path.relative_to(WATCH_DIRECTORY)
    except Exception:
        relative_path = file_path.name
    return f"Sent: {relative_path}"


def telegram_request(file_path: Path) -> tuple[str, str]:
    """
    根據副檔名決定要呼叫哪個 Telegram API 與 files key。
    """
    suffix = file_path.suffix.lower()

    if suffix in IMAGE_EXTENSIONS:
        return "sendPhoto", "photo"

    if suffix in VIDEO_EXTENSIONS:
        return "sendVideo", "video"

    raise ValueError(f"Unsupported file type: {suffix}")


def send_file_to_telegram(file_path: Path) -> bool:
    """
    根據檔案類型送到 Telegram。
    成功回傳 True，失敗回傳 False。
    """
    method, file_field = telegram_request(file_path)
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"

    caption = build_caption(file_path)

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            if not file_path.exists():
                log(f"File disappeared before upload: {file_path}")
                return False

            with open(file_path, "rb") as f:
                data = {
                    "chat_id": CHAT_ID,
                    "caption": caption,
                }

                # sendVideo 可加支援 streaming
                if method == "sendVideo":
                    data["supports_streaming"] = True

                response = requests.post(
                    url,
                    data=data,
                    files={file_field: f},
                    timeout=REQUEST_TIMEOUT,
                )

            if response.ok:
                log(f"Uploaded successfully: {file_path}")
                return True

            log(
                f"Upload failed (attempt {attempt}/{MAX_RETRIES}) "
                f"for {file_path}: {response.status_code} {response.text}"
            )

        except Exception as exc:
            log(
                f"Error uploading (attempt {attempt}/{MAX_RETRIES}) "
                f"{file_path}: {exc}"
            )

        if attempt < MAX_RETRIES:
            time.sleep(RETRY_DELAY)

    return False


def upload_and_maybe_delete(file_path: Path) -> None:
    """
    上傳前等待穩定，上傳成功後可選擇刪除。
    """
    if not is_supported_file(file_path):
        return

    if not wait_until_file_is_stable(file_path):
        log(f"Skipping unstable or missing file: {file_path}")
        return

    success = send_file_to_telegram(file_path)

    if success and DELETE_AFTER_SEND:
        try:
            file_path.unlink()
            log(f"Deleted: {file_path}")
        except FileNotFoundError:
            log(f"Already deleted: {file_path}")
        except Exception as exc:
            log(f"Failed to delete {file_path}: {exc}")


# =========================
# Watchdog Handler
# =========================
class MediaHandler(FileSystemEventHandler):
    def handle_path(self, src_path: str) -> None:
        file_path = Path(src_path)

        if is_supported_file(file_path):
            log(f"Detected new media: {file_path}")
            upload_and_maybe_delete(file_path)

    def on_created(self, event):
        if event.is_directory:
            return
        self.handle_path(event.src_path)

    def on_moved(self, event):
        if event.is_directory:
            return
        # 有些程式是先寫暫存檔，再 rename 成正式檔名
        self.handle_path(event.dest_path)


# =========================
# Initial Scan
# =========================
def process_existing_files(directory: str, recursive: bool = True) -> None:
    """
    啟動時掃描既有檔案。
    recursive=True 時會掃描所有子資料夾。
    """
    root = Path(directory)

    if not root.exists():
        log(f"Watch directory does not exist, creating: {root}")
        root.mkdir(parents=True, exist_ok=True)

    log(f"Scanning existing files (recursive={recursive})...")

    iterator = root.rglob("*") if recursive else root.iterdir()

    # 排序讓處理順序比較穩定
    for file_path in sorted(iterator):
        if is_supported_file(file_path):
            log(f"Found existing file: {file_path}")
            upload_and_maybe_delete(file_path)


# =========================
# Main
# =========================
def main() -> None:
    validate_env()

    watch_path = Path(WATCH_DIRECTORY)
    watch_path.mkdir(parents=True, exist_ok=True)

    # 1. 先掃描現有檔案（可深入子資料夾）
    # (已停用 initial scan，避免重新啟動時重複上傳未刪除的舊檔案)
    # process_existing_files(WATCH_DIRECTORY, recursive=RECURSIVE_WATCH)

    # 2. 再開始監控
    event_handler = MediaHandler()
    observer = Observer()
    observer.schedule(event_handler, str(watch_path), recursive=RECURSIVE_WATCH)

    log(f"Monitoring folder: {watch_path} (recursive={RECURSIVE_WATCH})")
    observer.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        log("Stopping observer...")
        observer.stop()

    observer.join()


if __name__ == "__main__":
    main()

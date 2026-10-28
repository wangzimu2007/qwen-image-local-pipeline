# -*- coding: utf-8 -*-
"""Audio workbench — native PySide6 desktop app (no Gradio / WebView)."""
import json
import os
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

from PySide6.QtCore import QEvent, QSettings, QThread, QTimer, Qt, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QFont, QGuiApplication, QPainter, QPalette, QPen, QPixmap
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFileDialog, QFormLayout, QGroupBox,
    QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow,
    QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QScrollArea,
    QSpinBox, QStackedWidget, QTabWidget, QVBoxLayout, QWidget, QFrame, QButtonGroup,
)

from desktop_backend import AudioBackend, AUDIO_EXTS, VIDEO_EXTS

IDLE_MINUTES = max(1, min(1440, int(os.environ.get("AUDIO_WORKBENCH_IDLE_MINUTES", "30"))))
IDLE_SECONDS = IDLE_MINUTES * 60
QUIT_FLAG = Path(__file__).resolve().parent / ".quit-request"

FILTERS = {
    "audio": "音频 (*.wav *.mp3 *.flac *.m4a *.ogg *.opus *.aac);;所有文件 (*.*)",
    "video": "视频 (*.mp4 *.mov *.mkv *.webm *.avi);;所有文件 (*.*)",
    "text": "文本或字幕 (*.txt *.srt *.md *.csv);;所有文件 (*.*)",
}
ALLOWED_EXTS = {
    "audio": AUDIO_EXTS,
    "video": VIDEO_EXTS,
    "text": {".txt", ".srt", ".md", ".csv"},
}

APP_QSS = """
QMainWindow, QWidget { background: #0d1117; color: #e6edf3;
    font-family: "Microsoft YaHei UI", "Segoe UI", sans-serif; font-size: 12pt; }
QLabel { background: transparent; color: #e6edf3; font-size: 12pt; }
QLabel#appTitle { font-size: 30px; font-weight: 800; color: #f0f6fc; }
QLabel#appSubtitle { color: #93a4bb; font-size: 11.5pt; }
QLabel#statusPill { color: #9ecbff; font-size: 11.5pt; background: #12243d; border: 1px solid #1f4b7a;
    border-radius: 12px; padding: 5px 12px; }
QTabWidget::pane { background: #11161f; border: 1px solid #263041; border-radius: 12px; top: -1px; }
QTabBar::tab { background: transparent; color: #8b98ab; padding: 11px 18px;
    margin-right: 6px; border-radius: 8px; font-size: 11.5pt; }
QTabBar::tab:selected { background: #1b2638; color: #e6edf3; border: 1px solid #2f4360; }
QTabBar::tab:hover { color: #e6edf3; background: #151d2a; }
QLineEdit, QPlainTextEdit, QComboBox, QSpinBox {
    background: #0b0f16; border: 1px solid #2a3444; border-radius: 8px;
    padding: 9px 12px; font-size: 12pt; color: #e6edf3; selection-background-color: #2f6fed; }
QLineEdit:focus, QPlainTextEdit:focus, QComboBox:focus, QSpinBox:focus { border: 1px solid #3b82f6; }
QLineEdit[dragActive="true"] { border: 1px solid #4ade80; background: #0f1f18; }
QPushButton { background: #1b2532; border: 1px solid #334155; border-radius: 9px;
    padding: 9px 16px; font-size: 11.5pt; color: #dbe7f3; }
QPushButton:hover { background: #243244; border-color: #475569; }
QPushButton:pressed { background: #111827; }
QPushButton:disabled { color: #64748b; background: #141b24; border-color: #1f2937; }
QPushButton[primary="true"] { background: #2563eb; border-color: #3b82f6;
    color: #ffffff; font-weight: 700; }
QPushButton[primary="true"]:hover { background: #1d4ed8; }
QGroupBox { border: 1px solid #263041; border-radius: 10px; margin-top: 12px;
    padding-top: 10px; background: #0f141c; font-weight: 600; color: #e6edf3; }
QGroupBox::title { subcontrol-origin: margin; left: 12px; padding: 0 6px; color: #93c5fd; }
QListWidget { background: #0b0f16; border: 1px solid #2a3444; border-radius: 10px; padding: 6px; color: #e6edf3; font-size: 12pt; }
QListWidget::item { padding: 8px; border-radius: 6px; }
QListWidget::item:selected { background: #1d3b66; color: #ffffff; }
QScrollArea { border: none; background: transparent; }
QProgressBar { background: #0b0f16; border: 1px solid #2a3444; border-radius: 7px;
    text-align: center; color: #cbd5e1; }
QProgressBar::chunk { background: #2563eb; border-radius: 7px; }
QScrollBar:vertical { background: #0d1117; width: 10px; margin: 0; }
QScrollBar::handle:vertical { background: #334155; border-radius: 5px; min-height: 30px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QScrollBar:horizontal { background: #0d1117; height: 10px; margin: 0; }
QScrollBar::handle:horizontal { background: #334155; border-radius: 5px; min-width: 30px; }
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal { width: 0; }
QCheckBox { spacing: 10px; font-size: 12pt; }
QCheckBox::indicator { width: 20px; height: 20px; border: 1px solid #465a73;
    border-radius: 5px; background: #0b0f16; }
QCheckBox::indicator:hover { border-color: #64748b; }
QCheckBox::indicator:checked { background: #2563eb; border: 1px solid #60a5fa; }
QToolTip { background: #1e293b; color: #e2e8f0; border: 1px solid #334155; font-size: 11.5pt; }
QListWidget#sideNav { background: #0a0e14; border: 1px solid #22303f; border-radius: 14px;
    padding: 10px 8px; font-size: 12pt; outline: none; }
QListWidget#sideNav::item { padding: 11px 14px; border-radius: 9px; color: #c6d4e6; }
QListWidget#sideNav::item:selected { background: #1d3b66; border: 1px solid #2f6fed; color: #ffffff; }
QListWidget#sideNav::item:hover { background: #15202f; }
QListWidget#sideNav::item:disabled { color: #7d93ab; font-weight: 700; }
QLabel#pageTitle { font-size: 21px; font-weight: 800; color: #f0f6fc; padding: 2px 4px 4px 4px; }
QWidget#inspector { background: #0a0f16; border: 1px solid #22303f; border-radius: 14px; }
QLabel#inspectorTitle { font-size: 14pt; font-weight: 800; color: #e6edf3; }
QWidget#taskCenter { background: #0a0f16; border: 1px solid #22303f; border-radius: 12px; }
QLabel#taskCenterTitle { color: #8fb6e8; font-weight: 700; font-size: 10.5pt; }
QPushButton:checked { background: #1d3b66; border-color: #3b82f6; color: #ffffff; }
QLabel#queuePill { color: #a7f3d0; font-size: 11pt; background: #0d2a1f; border: 1px solid #14532d;
    border-radius: 10px; padding: 4px 10px; }
QScrollArea { border: none; background: transparent; }
"""



class TaskThread(QThread):
    done = Signal(object)

    def __init__(self, fn, args):
        super().__init__()
        self.fn = fn
        self.args = args

    def run(self):
        try:
            result = self.fn(*self.args)
            if not isinstance(result, dict):
                result = {"log": str(result), "files": [], "preview": None}
            self.done.emit(result)
        except Exception as exc:
            self.done.emit({
                "log": "任务异常：\n" + traceback.format_exc(),
                "files": [],
                "preview": None,
                "ok": False,
            })


def local_file_from_mime(mime, exts):
    if not mime.hasUrls():
        return None
    for url in mime.urls():
        if not url.isLocalFile():
            continue
        path = Path(url.toLocalFile())
        if path.is_file() and path.suffix.lower() in exts:
            return str(path)
    return None


class DropLineEdit(QLineEdit):
    fileDropped = Signal(str)

    def __init__(self, exts, parent=None):
        super().__init__(parent)
        self.exts = set(exts)
        self.setAcceptDrops(True)
        self.setClearButtonEnabled(True)
        self.setPlaceholderText("把文件拖到这里，或点“选择…”")

    def _drag_state(self, active):
        self.setProperty("dragActive", active)
        self.style().unpolish(self)
        self.style().polish(self)

    def dragEnterEvent(self, event):
        if local_file_from_mime(event.mimeData(), self.exts):
            event.acceptProposedAction()
            self._drag_state(True)
        else:
            event.ignore()

    def dragLeaveEvent(self, event):
        self._drag_state(False)
        super().dragLeaveEvent(event)

    def dropEvent(self, event):
        path = local_file_from_mime(event.mimeData(), self.exts)
        self._drag_state(False)
        if path:
            self.setText(path)
            self.setToolTip(path)
            self.fileDropped.emit(path)
            event.acceptProposedAction()
        else:
            event.ignore()


class PathRow(QWidget):
    def __init__(self, label, kind="audio", parent=None):
        super().__init__(parent)
        self.kind = kind
        self.exts = ALLOWED_EXTS[kind]
        self.setAcceptDrops(True)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)
        cap = QLabel(label)
        cap.setStyleSheet("color:#cbd5e1;font-weight:600;")
        lay.addWidget(cap, 0)
        self.edit = DropLineEdit(self.exts)
        lay.addWidget(self.edit, 1)
        btn = QPushButton("选择…")
        btn.setFixedWidth(104)
        btn.setProperty("secondary", True)
        btn.setStyleSheet(
            "QPushButton{color:#e6edf3;background:#1b2532;border:1px solid #465a73;"
            "border-radius:8px;padding:5px 8px;}"
            "QPushButton:hover{background:#243244;border-color:#64748b;}"
        )
        btn.clicked.connect(self.pick)
        lay.addWidget(btn, 0)
        self.edit.fileDropped.connect(self._set_path)
        self._settings_key = "paths/" + label
        self._restore_path()
        self.edit.textChanged.connect(self._save_path)

    def _restore_path(self):
        try:
            val = QSettings("DeepSeekHarness", "AudioWorkbench").value(self._settings_key, "")
            if val and Path(val).exists():
                self.edit.setText(str(val))
                self.edit.setToolTip(str(val))
        except Exception:
            pass

    def _save_path(self, *_):
        try:
            QSettings("DeepSeekHarness", "AudioWorkbench").setValue(
                self._settings_key, self.edit.text().strip())
        except Exception:
            pass

    def _set_path(self, path):
        self.edit.setText(path)
        self.edit.setToolTip(path)
        self._save_path()

    def pick(self):
        path, _ = QFileDialog.getOpenFileName(self, "选择文件", str(Path.home()), FILTERS[self.kind])
        if path:
            self._set_path(path)

    def path(self):
        return self.edit.text().strip()

    def _drag_state(self, active):
        self.edit.setProperty("dragActive", active)
        self.edit.style().unpolish(self.edit)
        self.edit.style().polish(self.edit)

    def dragEnterEvent(self, event):
        if local_file_from_mime(event.mimeData(), self.exts):
            event.acceptProposedAction()
            self._drag_state(True)
        else:
            event.ignore()

    def dragLeaveEvent(self, event):
        self._drag_state(False)
        super().dragLeaveEvent(event)

    def dropEvent(self, event):
        path = local_file_from_mime(event.mimeData(), self.exts)
        self._drag_state(False)
        if path:
            self._set_path(path)
            event.acceptProposedAction()
        else:
            event.ignore()



class FolderRow(QWidget):
    def __init__(self, label, parent=None):
        super().__init__(parent)
        self.setAcceptDrops(True)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)
        cap = QLabel(label)
        cap.setStyleSheet("color:#cbd5e1;font-weight:600;")
        lay.addWidget(cap, 0)
        self.edit = QLineEdit()
        self.edit.setPlaceholderText("拖入文件夹，或点“选择…”")
        lay.addWidget(self.edit, 1)
        btn = QPushButton("选择…")
        btn.setFixedWidth(104)
        btn.setProperty("secondary", True)
        btn.setStyleSheet(
            "QPushButton{color:#e6edf3;background:#1b2532;border:1px solid #465a73;"
            "border-radius:8px;padding:5px 8px;}"
            "QPushButton:hover{background:#243244;border-color:#64748b;}"
        )
        btn.clicked.connect(self.pick)
        lay.addWidget(btn, 0)

    def pick(self):
        path = QFileDialog.getExistingDirectory(self, "选择文件夹", str(Path.home() / "Desktop"))
        if path:
            self.edit.setText(path)

    def path(self):
        return self.edit.text().strip()

    @staticmethod
    def _folder_from_mime(mime):
        if not mime.hasUrls():
            return None
        for url in mime.urls():
            if url.isLocalFile():
                p = Path(url.toLocalFile())
                if p.is_dir():
                    return str(p)
        return None

    def dragEnterEvent(self, event):
        if self._folder_from_mime(event.mimeData()):
            event.acceptProposedAction()
        else:
            event.ignore()

    def dropEvent(self, event):
        path = self._folder_from_mime(event.mimeData())
        if path:
            self.edit.setText(path)
            event.acceptProposedAction()
        else:
            event.ignore()


class OutputList(QListWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumHeight(110)
        self.itemDoubleClicked.connect(self.open_item)

    def set_paths(self, paths):
        self.clear()
        for path in paths or []:
            if not Path(path).exists():
                continue
            item = QListWidgetItem(Path(path).name)
            item.setToolTip(path)
            item.setData(Qt.UserRole, path)
            self.addItem(item)

    def open_item(self, item):
        path = item.data(Qt.UserRole)
        if path:
            QDesktopServices.openUrl(QUrl.fromLocalFile(path))


class SeekLabel(QLabel):
    """点哪跳哪的波形标签。"""
    clicked = Signal(float)

    def mousePressEvent(self, event):
        if self.width() > 0:
            ratio = max(0.0, min(1.0, event.position().x() / self.width()))
            self.clicked.emit(ratio)
        super().mousePressEvent(event)


class InspectorPanel(QWidget):
    """右侧预览/检查器：视频帧、波形、音频信息、播放。"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("inspector")
        self.setFixedWidth(370)
        self._path = ""
        self._is_video = False
        self.player = None
        self.audio_out = None
        self.video = None

        v = QVBoxLayout(self)
        v.setContentsMargins(14, 14, 14, 14)
        v.setSpacing(10)
        title = QLabel("预览 / 检查器")
        title.setObjectName("inspectorTitle")
        v.addWidget(title)

        self.stack = QStackedWidget()
        self.thumb = QLabel("视频预览")
        self.thumb.setAlignment(Qt.AlignCenter)
        self.thumb.setMinimumHeight(190)
        self.thumb.setStyleSheet("background:#05070b;border:1px solid #1b2634;border-radius:8px;color:#5b6b80;")
        self.stack.addWidget(self.thumb)
        try:
            from PySide6.QtMultimediaWidgets import QVideoWidget
            self.video = QVideoWidget()
            self.video.setMinimumHeight(190)
            self.stack.addWidget(self.video)
        except Exception:
            self.video = None
        v.addWidget(self.stack)

        self.wave = SeekLabel("选择视频/音频后显示波形")
        self.wave.clicked.connect(self.seek_ratio)
        self._wave_pix = None
        self._pos_ratio = 0.0
        self.wave.setAlignment(Qt.AlignCenter)
        self.wave.setMinimumHeight(120)
        self.wave.setStyleSheet("background:#05070b;border:1px solid #1b2634;border-radius:8px;color:#5b6b80;")
        v.addWidget(self.wave)

        self.info = QLabel("尚未选择媒体")
        self.info.setWordWrap(True)
        self.info.setStyleSheet("color:#93a4bb;font-size:11pt;")
        v.addWidget(self.info)

        row = QHBoxLayout()
        self.play_btn = QPushButton("▶ 播放")
        self.play_btn.setEnabled(False)
        self.play_btn.clicked.connect(self.toggle_play)
        self.open_btn = QPushButton("打开")
        self.open_btn.setEnabled(False)
        self.open_btn.clicked.connect(self.open_external)
        row.addWidget(self.play_btn)
        row.addWidget(self.open_btn)
        v.addLayout(row)
        v.addStretch(1)

        try:
            from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
            self.player = QMediaPlayer(self)
            self.audio_out = QAudioOutput(self)
            self.player.setAudioOutput(self.audio_out)
            if self.video is not None:
                self.player.setVideoOutput(self.video)
            self.player.playbackStateChanged.connect(self._on_state)
            self.player.positionChanged.connect(self._on_position)
        except Exception:
            self.player = None

    @staticmethod
    def _ffprobe(path):
        try:
            p = subprocess.run(
                [r"D:\tools\ffmpeg\bin\ffprobe.exe", "-v", "error", "-show_entries",
                 "format=duration,size:stream=codec_type,width,height,sample_rate,channels",
                 "-of", "json", str(path)],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
            return json.loads(p.stdout or "{}")
        except Exception:
            return {}

    def _make_frame(self, path):
        try:
            out = Path(tempfile.gettempdir()) / ("wb_frame_" + str(abs(hash(path))) + ".png")
            subprocess.run(
                [r"D:\tools\ffmpeg\bin\ffmpeg.exe", "-y", "-ss", "0", "-i", str(path),
                 "-frames:v", "1", "-vf", "scale=320:-2", str(out)],
                capture_output=True, timeout=60)
            pix = QPixmap(str(out))
            return pix if not pix.isNull() else None
        except Exception:
            return None

    def _make_wave(self, path):
        try:
            out = Path(tempfile.gettempdir()) / ("wb_wave_" + str(abs(hash(path))) + ".png")
            subprocess.run(
                [r"D:\tools\ffmpeg\bin\ffmpeg.exe", "-y", "-t", "120", "-i", str(path),
                 "-filter_complex", "showwavespic=s=680x130:colors=#3b82f6",
                 "-frames:v", "1", str(out)],
                capture_output=True, timeout=90)
            pix = QPixmap(str(out))
            return pix if not pix.isNull() else None
        except Exception:
            return None

    def _show_thumb(self):
        if self._is_video and self.video is not None:
            self.stack.setCurrentWidget(self.thumb)

    def show_media(self, path):
        path = (path or "").strip()
        if not path or not Path(path).exists():
            return
        self._path = path
        if self.player is not None:
            self.player.stop()
        ext = Path(path).suffix.lower()
        self._is_video = ext in {".mp4", ".mov", ".mkv", ".webm", ".avi"}
        if self._is_video:
            self.stack.show()
            pix = self._make_frame(path)
            if pix is not None:
                self.thumb.setPixmap(pix.scaledToWidth(330, Qt.SmoothTransformation))
                self.thumb.setText("")
            else:
                self.thumb.setText("视频（无法提取画面）")
            self._show_thumb()
        else:
            self.stack.hide()
        wave = self._make_wave(path)
        if wave is not None:
            self._wave_pix = wave.scaledToWidth(330, Qt.SmoothTransformation)
            self._pos_ratio = 0.0
            self._draw_wave()
        else:
            self._wave_pix = None
            self.wave.setPixmap(QPixmap())
            self.wave.setText("无音轨或波形生成失败")
        info = self._ffprobe(path)
        fmt = info.get("format", {}) or {}
        sec = float(fmt.get("duration") or 0)
        size = float(fmt.get("size") or 0) / 1024 / 1024
        lines = [f"文件：{Path(path).name}", f"时长：{sec:.1f}s · 大小：{size:.1f} MB"]
        for st in info.get("streams", []) or []:
            if st.get("codec_type") == "video":
                lines.append(f"画面：{st.get('width')}×{st.get('height')}")
            elif st.get("codec_type") == "audio":
                lines.append(f"音频：{st.get('sample_rate')} Hz · {st.get('channels')} 声道")
        self.info.setText("\n".join(lines))
        if self.player is not None:
            self.player.setSource(QUrl.fromLocalFile(path))
        self.play_btn.setEnabled(self.player is not None)
        self.open_btn.setEnabled(True)

    def _draw_wave(self):
        if self._wave_pix is None:
            return
        pix = self._wave_pix.copy()
        painter = QPainter(pix)
        pen = QPen(QColor("#f59e0b"))
        pen.setWidth(2)
        painter.setPen(pen)
        x = int(max(0.0, min(1.0, self._pos_ratio)) * max(1, pix.width() - 1))
        painter.drawLine(x, 0, x, pix.height())
        painter.end()
        self.wave.setPixmap(pix)

    def seek_ratio(self, ratio):
        if self.player is None or self._wave_pix is None:
            return
        dur = self.player.duration()
        if dur <= 0:
            return
        self.player.setPosition(int(dur * max(0.0, min(1.0, ratio))))
        if self.player.playbackState() != self.player.PlaybackState.PlayingState:
            self.player.play()

    def _on_position(self, pos):
        dur = self.player.duration() if self.player is not None else 0
        if dur > 0:
            self._pos_ratio = pos / dur
            self._draw_wave()

    def show_result(self, files):
        files = [str(x) for x in (files or []) if Path(str(x)).exists()]
        if not files:
            return
        videos = [x for x in files if Path(x).suffix.lower() in {".mp4", ".mov", ".mkv", ".webm"}]
        audit = [x for x in files if Path(x).suffix.lower() in {".wav", ".mp3", ".flac", ".m4a"}]
        if videos:
            self.show_media(videos[0])
        elif audit:
            self.show_media(audit[0])

    def toggle_play(self):
        if self.player is None:
            return
        if self.player.playbackState() == self.player.PlaybackState.PlayingState:
            self.player.stop()
            self._show_thumb()
            return
        if self._is_video and self.video is not None:
            self.stack.setCurrentWidget(self.video)
        self.player.play()

    def _on_state(self, state):
        if self.player is None:
            return
        playing = state == self.player.PlaybackState.PlayingState
        self.play_btn.setText("⏸ 暂停" if playing else "▶ 播放")
        if not playing:
            self._show_thumb()
            self._pos_ratio = 0.0
            self._draw_wave()

    def open_external(self):
        if self._path:
            QDesktopServices.openUrl(QUrl.fromLocalFile(self._path))


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        try:
            if QUIT_FLAG.exists(): QUIT_FLAG.unlink()
        except OSError:
            pass
        self.backend = AudioBackend()
        self.worker = None
        self.task_queue = []
        self.action_buttons = []
        self.batch_seen = set()
        self.batch_watch_timer = QTimer(self)
        self.setWindowTitle("本地音频工作台 · 桌面版")
        screen = QGuiApplication.primaryScreen().availableGeometry()
        w = min(1440, max(1120, screen.width() - 60))
        h = min(940, max(760, screen.height() - 60))
        self.resize(w, h)
        self.move(screen.x() + (screen.width() - w) // 2,
                  screen.y() + (screen.height() - h) // 2)
        self.setMinimumSize(1060, 720)

        root = QWidget()
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)
        layout.setContentsMargins(18, 16, 18, 16)
        layout.setSpacing(12)
        self.inspector = InspectorPanel()

        header = QHBoxLayout()
        header.setSpacing(14)
        title_box = QVBoxLayout()
        title_box.setSpacing(2)
        title = QLabel("本地音频工作台")
        title.setObjectName("appTitle")
        title.setStyleSheet("color:#f0f6fc;font-size:30px;font-weight:800;")
        subtitle = QLabel("Whisper · Demucs · Chatterbox · ACE-Step  |  文件可直接拖入")
        subtitle.setObjectName("appSubtitle")
        subtitle.setStyleSheet("color:#93a4bb;font-size:11.5pt;")
        title_box.addWidget(title)
        title_box.addWidget(subtitle)
        header.addLayout(title_box)
        header.addSpacing(8)
        self.status_label = QLabel(f"● 就绪 · 空闲 {IDLE_MINUTES} 分钟自动退出")
        self.status_label.setObjectName("statusPill")
        self.status_label.setStyleSheet(
            "color:#9ecbff;font-size:11.5pt;background:#12243d;border:1px solid #1f4b7a;"
            "border-radius:12px;padding:5px 12px;")
        header.addWidget(self.status_label, 0)
        self.queue_label = QLabel("队列 0")
        self.queue_label.setObjectName("queuePill")
        header.addWidget(self.queue_label)
        header.addStretch(1)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setFixedWidth(130)
        self.progress.hide()
        header.addWidget(self.progress)
        self.task_center_btn = QPushButton("收起任务中心")
        self.task_center_btn.setProperty("secondary", True)
        self.task_center_btn.setStyleSheet(
            "QPushButton{color:#e6edf3;background:#1b2532;border:1px solid #465a73;"
            "border-radius:8px;padding:6px 12px;}"
            "QPushButton:hover{background:#243244;border-color:#64748b;}")
        self.task_center_btn.clicked.connect(self._toggle_task_center)
        header.addWidget(self.task_center_btn)
        self.preview_btn = QPushButton("收起预览")
        self.preview_btn.setProperty("secondary", True)
        self.preview_btn.setStyleSheet(
            "QPushButton{color:#e6edf3;background:#1b2532;border:1px solid #465a73;"
            "border-radius:8px;padding:6px 12px;}"
            "QPushButton:hover{background:#243244;border-color:#64748b;}")
        self.preview_btn.clicked.connect(self._toggle_inspector)
        header.addWidget(self.preview_btn)
        quit_btn = QPushButton("退出工作台")
        quit_btn.setProperty("secondary", True)
        quit_btn.setStyleSheet(
            "QPushButton{color:#e6edf3;background:#1b2532;border:1px solid #465a73;"
            "border-radius:8px;padding:6px 12px;}"
            "QPushButton:hover{background:#243244;border-color:#64748b;}"
        )
        quit_btn.clicked.connect(self.close)
        header.addWidget(quit_btn)
        layout.addLayout(header)

        self.nav = QListWidget()
        self.nav.setObjectName("sideNav")
        self.nav.setFixedWidth(224)
        self.nav.setSpacing(2)
        self.nav.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.page_title = QLabel("视频配音")
        self.page_title.setObjectName("pageTitle")
        self.stack = QStackedWidget()
        right = QVBoxLayout()
        right.setContentsMargins(0, 0, 0, 0)
        right.setSpacing(10)
        right.addWidget(self.page_title)
        right.addWidget(self.stack, 1)
        body = QWidget()
        body_lay = QHBoxLayout(body)
        body_lay.setContentsMargins(0, 0, 0, 0)
        body_lay.setSpacing(16)
        body_lay.addWidget(self.nav)
        body_lay.addLayout(right, 1)
        body_lay.addWidget(self.inspector)
        layout.addWidget(body, 1)

        self.task_center = QWidget()
        self.task_center.setObjectName("taskCenter")
        tc = QHBoxLayout(self.task_center)
        tc.setContentsMargins(12, 8, 12, 8)
        tc.setSpacing(12)
        qbox = QVBoxLayout()
        qlabel = QLabel("任务队列")
        qlabel.setObjectName("taskCenterTitle")
        qbox.addWidget(qlabel)
        self.queue_list = QListWidget()
        self.queue_list.setFixedHeight(92)
        qbox.addWidget(self.queue_list)
        rbox = QVBoxLayout()
        rlabel = QLabel("最近产物（双击打开）")
        rlabel.setObjectName("taskCenterTitle")
        rbox.addWidget(rlabel)
        self.recent_list = QListWidget()
        self.recent_list.setFixedHeight(92)
        self.recent_list.itemDoubleClicked.connect(self._open_recent)
        self.recent_list.itemClicked.connect(self._preview_recent)
        rbox.addWidget(self.recent_list)
        tc.addLayout(qbox, 1)
        tc.addLayout(rbox, 1)
        layout.addWidget(self.task_center)
        self._load_recent()

        nav_spec = [
            ("常用", None),
            ("视频配音", self.tab_video_dub),
            ("克隆 / TTS", self.tab_clone),
            ("声音库", self.tab_voice_library),
            ("处理", None),
            ("一键处理", self.tab_pipeline),
            ("批量处理", self.tab_batch),
            ("转写 / 字幕", self.tab_subtitle),
            ("分离 / 降噪 / 超分", self.tab_tools),
            ("音乐生成（实验）", self.tab_music),
            ("素材采集", self.tab_collect),
            ("工具", None),
            ("高级工具", self.tab_advanced),
            ("说话人 / MIDI", self.tab_diar_midi),
            ("状态 / 配置", self.tab_status),
        ]
        self.nav.blockSignals(True)
        first_row = -1
        for label, builder in nav_spec:
            if builder is None:
                it = QListWidgetItem(label)
                it.setFlags(Qt.NoItemFlags)
                it.setData(Qt.UserRole, -1)
                f = it.font(); f.setBold(True); it.setFont(f)
                self.nav.addItem(it)
                continue
            page = self._scroll_wrap(builder())
            self.stack.addWidget(page)
            it = QListWidgetItem("  " + label)
            it.setData(Qt.UserRole, self.stack.count() - 1)
            self.nav.addItem(it)
            if first_row < 0:
                first_row = self.nav.count() - 1
        self.nav.blockSignals(False)
        self.nav.currentRowChanged.connect(self._on_nav_changed)
        if first_row >= 0:
            self.nav.setCurrentRow(first_row)
        self.polish_labels()

    def _scroll_wrap(self, page):
        sa = QScrollArea()
        sa.setWidgetResizable(True)
        sa.setFrameShape(QFrame.NoFrame)
        sa.setWidget(page)
        return sa

    def _on_nav_changed(self, row):
        if row < 0:
            return
        item = self.nav.item(row)
        idx = item.data(Qt.UserRole) if item else -1
        if idx is None or idx < 0:
            return
        self.stack.setCurrentIndex(idx)
        self.page_title.setText(item.text().strip())

        self.idle_timer = QTimer(self)
        self.idle_timer.timeout.connect(self.check_idle)
        self.idle_timer.start(30000)
        self.quit_timer = QTimer(self)
        self.quit_timer.timeout.connect(self.check_quit_flag)
        self.quit_timer.start(500)
        self.batch_watch_timer.timeout.connect(self.check_batch_watch)
        self.batch_watch_timer.start(20000)
        QApplication.instance().installEventFilter(self)

    def polish_labels(self):
        for lab in self.findChildren(QLabel):
            name = lab.objectName()
            if name == "appTitle":
                lab.setStyleSheet("color:#f0f6fc;font-size:30px;font-weight:800;background:transparent;")
            elif name == "appSubtitle":
                lab.setStyleSheet("color:#93a4bb;font-size:11.5pt;background:transparent;")
            elif name == "statusPill":
                lab.setStyleSheet(
                    "color:#9ecbff;font-size:11.5pt;background:#12243d;border:1px solid #1f4b7a;"
                    "border-radius:12px;padding:5px 12px;")
            elif name == "pageTitle":
                lab.setStyleSheet("color:#f0f6fc;font-size:21px;font-weight:800;background:transparent;")
            elif name == "sectionLabel":
                lab.setStyleSheet("color:#8fb6e8;font-weight:700;font-size:12pt;background:transparent;margin-top:6px;")
            else:
                lab.setStyleSheet("color:#cbd5e1;background:transparent;")
        for box in self.findChildren(QGroupBox):
            box.setStyleSheet("QGroupBox{color:#e6edf3;} QGroupBox::title{color:#93c5fd;}")

    def showEvent(self, event):
        super().showEvent(event)
        QTimer.singleShot(1000, self.polish_labels)

    # ---------- shared widgets ----------

    def log_widget(self):
        w = QPlainTextEdit()
        w.setReadOnly(True)
        w.setFont(QFont("Consolas", 9))
        w.setMinimumHeight(180)
        w.setMaximumHeight(380)
        w.setPlaceholderText("运行日志会显示在这里…")
        return w

    def add_run_button(self, layout, text, slot, primary=True):
        btn = QPushButton(text)
        btn.setProperty("primary", bool(primary))
        btn.clicked.connect(slot)
        layout.addWidget(btn)
        self.action_buttons.append(btn)
        return btn

    def set_busy(self, busy, text="运行中…"):
        # 任务运行中按钮保持可点：再点会进入队列（不再弹“请等它完成”）
        self.progress.setVisible(busy)
        self.status_label.setText(text if busy else f"● 就绪 · 空闲 {IDLE_MINUTES} 分钟自动退出")

    def start_task(self, fn, args, log, outputs, preview_label=None, label=""):
        label = label or self._task_label(fn)
        if self.backend.is_busy() or self.worker is not None:
            self.task_queue.append((fn, args, log, outputs, preview_label, label))
            self._update_queue_label()
            self.status_label.setText(f"＋ 已排队 {len(self.task_queue)} 个任务 · 当前完成后自动执行")
            return
        self.backend.touch()
        log.clear()
        outputs.clear()
        if preview_label:
            preview_label.setText("")
        self._current_label = label
        self.set_busy(True, "任务运行中，请稍候…")
        self.worker = TaskThread(fn, args)
        self.worker.done.connect(lambda result: self.finish_task(result, log, outputs, preview_label))
        self.worker.start()
        self._update_queue_label()

    def _task_label(self, fn):
        names = {
            "prompt_dub": "视频配音", "video_dub": "手动配音", "clone": "克隆 / TTS",
            "tts": "Kokoro 合成", "subtitle": "转写 / 字幕", "split": "分离音频",
            "denoise": "降噪", "sr": "音频超分", "diarize": "说话人分离",
            "midi": "转 MIDI", "music": "音乐生成", "pipeline": "一键处理",
            "generate_voice": "声音库生成", "batch": "批量处理",
        }
        return names.get(getattr(fn, "__name__", ""), getattr(fn, "__name__", "任务"))

    def _refresh_queue_view(self):
        if not hasattr(self, "queue_list"):
            return
        self.queue_list.clear()
        if getattr(self, "worker", None) is not None:
            self.queue_list.addItem("▶ " + getattr(self, "_current_label", "任务") + "（运行中）")
        for i, item in enumerate(self.task_queue, 1):
            label = item[5] if len(item) > 5 else "任务"
            self.queue_list.addItem(f"{i}. {label}")

    def _load_recent(self):
        if not hasattr(self, "recent_list"):
            return
        try:
            paths = QSettings("DeepSeekHarness", "AudioWorkbench").value("recent/files", [])
        except Exception:
            paths = []
        if isinstance(paths, str):
            paths = [paths]
        self._recent_paths = [str(p) for p in (paths or []) if str(p) and Path(str(p)).exists()]
        self._refresh_recent()

    def _refresh_recent(self):
        self.recent_list.clear()
        for p in getattr(self, "_recent_paths", []):
            it = QListWidgetItem(Path(p).name)
            it.setData(Qt.UserRole, p)
            it.setToolTip(p)
            self.recent_list.addItem(it)

    def _add_recent(self, files):
        files = [str(x) for x in (files or []) if Path(str(x)).exists()]
        if not files:
            return
        cur = list(getattr(self, "_recent_paths", []))
        merged = []
        for p in files + cur:
            if p not in merged:
                merged.append(p)
        self._recent_paths = merged[:12]
        try:
            QSettings("DeepSeekHarness", "AudioWorkbench").setValue("recent/files", self._recent_paths)
        except Exception:
            pass
        self._refresh_recent()

    def _preview_recent(self, item):
        path = item.data(Qt.UserRole)
        if path and Path(path).exists():
            self.inspector.show_media(path)

    def _open_recent(self, item):
        path = item.data(Qt.UserRole)
        if path and Path(path).exists():
            QDesktopServices.openUrl(QUrl.fromLocalFile(path))

    def _toggle_task_center(self):
        visible = self.task_center.isVisible()
        self.task_center.setVisible(not visible)
        self.task_center_btn.setText("显示任务中心" if visible else "收起任务中心")

    def _toggle_inspector(self):
        visible = self.inspector.isVisible()
        self.inspector.setVisible(not visible)
        self.preview_btn.setText("显示预览" if visible else "收起预览")

    def _update_queue_label(self):
        n = len(getattr(self, "task_queue", []))
        self.queue_label.setText(f"队列 {n}" if n else "队列 0")
        self._refresh_queue_view()

    def _preview_path(self, path):
        if path and Path(path).exists():
            self.inspector.show_media(path)

    def finish_task(self, result, log, outputs, preview_label):
        self.backend.touch()
        ok = bool(result.get("ok", True))
        log.setPlainText(result.get("log") or "(无日志)")
        outputs.set_paths(result.get("files") or [])
        if preview_label:
            preview = result.get("preview") or ""
            preview_label.setText(("成品：" + preview) if preview else "")
        self.set_busy(False)
        if self.worker:
            self.worker.deleteLater()
            self.worker = None
        if not ok:
            self.status_label.setText("✗ 任务失败 · 请查看运行日志")
        elif result.get("files"):
            self.status_label.setText("✓ 完成 · 产物已生成")
        else:
            self.status_label.setText("✓ 完成（无产物文件）")
        try:
            self.inspector.show_result(result.get("files") or [])
        except Exception:
            pass
        self._add_recent(result.get("files") or [])
        self._current_label = ""
        self._update_queue_label()
        if self.task_queue:
            nxt = self.task_queue.pop(0)
            self.status_label.setText(f"▶ 队列执行中 · 剩余 {len(self.task_queue)} 个")
            QTimer.singleShot(0, lambda: self.start_task(*nxt))

    def require(self, path, name):
        if not path:
            QMessageBox.warning(self, "缺少输入", f"请选择{name}。")
            return False
        if not Path(path).exists():
            QMessageBox.warning(self, "文件不存在", path)
            return False
        return True

    def require_text(self, text, name):
        if not text or not text.strip():
            QMessageBox.warning(self, "缺少输入", f"请填写{name}。")
            return False
        return True

    def output_block(self, layout):
        log = self.log_widget()
        log.setMaximumHeight(240)
        outputs = OutputList()
        log_box = QGroupBox("运行日志")
        log_box.setMinimumHeight(220)
        log_box.setMaximumHeight(330)
        log_lay = QVBoxLayout(log_box)
        log_lay.setContentsMargins(10, 14, 10, 10)
        log_lay.addWidget(log)
        out_box = QGroupBox("产物 · 双击打开")
        out_box.setMinimumHeight(160)
        out_box.setMaximumHeight(230)
        out_lay = QVBoxLayout(out_box)
        out_lay.setContentsMargins(10, 14, 10, 10)
        out_lay.addWidget(outputs)
        layout.addWidget(log_box, 0)
        layout.addWidget(out_box, 0)
        return log, outputs

    # ---------- tabs ----------

    def tab_pipeline(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.pipe_audio = PathRow("输入音频", "audio")
        v.addWidget(self.pipe_audio)
        row = QHBoxLayout()
        self.pipe_preset = QComboBox()
        self.pipe_preset.addItems([
            "完整音频链：分离 + 降噪 + 字幕 + MIDI",
            "降噪 + 字幕", "超分 + 字幕", "说话人分离 + 字幕",
        ])
        self.pipe_preset.setMinimumWidth(430)
        self.pipe_lang = QComboBox()
        self.pipe_lang.addItems(["zh", "en", "auto", "ja"])
        row.addWidget(QLabel("处理链"))
        row.addWidget(self.pipe_preset, 1)
        row.addWidget(QLabel("字幕语言"))
        row.addWidget(self.pipe_lang)
        v.addLayout(row)
        self.add_run_button(v, "开始处理", self.run_pipeline)
        self._pipe_log, self._pipe_out = self.output_block(v)
        v.addWidget(QLabel("完整链会自动做分离、降噪、字幕和 MIDI；GPU 任务会先过显存门禁。"))
        return w

    def run_pipeline(self):
        if not self.require(self.pipe_audio.path(), "音频"):
            return
        self.start_task(self.backend.pipeline,
                        (self.pipe_audio.path(), self.pipe_preset.currentText(),
                         self.pipe_lang.currentText()),
                        self._pipe_log, self._pipe_out)

    def tab_batch(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.batch_dir = FolderRow("待处理文件夹")
        v.addWidget(self.batch_dir)
        row = QHBoxLayout()
        self.batch_preset = QComboBox()
        self.batch_preset.addItems([
            "仅转写 / 字幕", "降噪 + 字幕", "完整音频链", "说话人 + 字幕",
        ])
        self.batch_lang = QComboBox()
        self.batch_lang.addItems(["zh", "en", "auto", "ja"])
        row.addWidget(QLabel("批量模式"))
        row.addWidget(self.batch_preset, 1)
        row.addWidget(QLabel("字幕语言"))
        row.addWidget(self.batch_lang)
        v.addLayout(row)
        self.batch_watch = QCheckBox("持续监控：新文件自动处理（每 20 秒扫描）")
        v.addWidget(self.batch_watch)
        self.add_run_button(v, "开始批量", self.run_batch)
        self._batch_log, self._batch_out = self.output_block(v)
        v.addWidget(QLabel("按文件名顺序逐个处理，不并发；监控模式不会重复处理已入队文件。"))
        return w

    def scan_batch_files(self, folder):
        root = Path(folder)
        exts = AUDIO_EXTS | VIDEO_EXTS
        if not root.is_dir():
            return []
        return sorted(
            (p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in exts),
            key=lambda p: str(p).lower(),
        )

    def run_batch(self):
        folder = self.batch_dir.path()
        if not folder or not Path(folder).is_dir():
            QMessageBox.warning(self, "文件夹无效", "请选择一个存在的待处理文件夹。")
            return
        files = self.scan_batch_files(folder)
        self.batch_seen = {str(p) for p in files}
        if not files:
            if self.batch_watch.isChecked():
                QMessageBox.information(
                    self, "已开启监控",
                    "当前文件夹没有音频/视频。保持窗口开启，新文件会自动处理。")
            else:
                QMessageBox.information(self, "没有文件", "文件夹里没有可处理的音频或视频。")
            return
        self.start_task(self.backend.batch,
                        (files, self.batch_preset.currentText(), self.batch_lang.currentText()),
                        self._batch_log, self._batch_out)

    def check_batch_watch(self):
        if not self.batch_watch.isChecked() or self.backend.is_busy():
            return
        folder = self.batch_dir.path()
        if not folder or not Path(folder).is_dir():
            return
        files = [p for p in self.scan_batch_files(folder) if str(p) not in self.batch_seen]
        if not files:
            return
        self.batch_seen.update(str(p) for p in files)
        self.start_task(self.backend.batch,
                        (files, self.batch_preset.currentText(), self.batch_lang.currentText()),
                        self._batch_log, self._batch_out)

    def tab_subtitle(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.sub_file = PathRow("音频或视频", "audio")
        v.addWidget(self.sub_file)
        row = QHBoxLayout()
        self.sub_model = QComboBox()
        self.sub_model.addItems(["large-v3-turbo", "small", "medium", "large-v3"])
        self.sub_lang = QComboBox()
        self.sub_lang.addItems(["auto", "zh", "en", "ja"])
        self.sub_fmt = QLineEdit("srt,txt,json")
        row.addWidget(QLabel("模型")); row.addWidget(self.sub_model)
        row.addWidget(QLabel("语言")); row.addWidget(self.sub_lang)
        row.addWidget(QLabel("格式")); row.addWidget(self.sub_fmt, 1)
        v.addLayout(row)
        self.add_run_button(v, "转写", self.run_subtitle)
        v.addWidget(QLabel("字幕翻译（本地 Qwen 9B，不下载新模型）"))
        self.trans_file = PathRow("字幕 / 文本", "text")
        v.addWidget(self.trans_file)
        row_tr = QHBoxLayout()
        self.trans_from = QComboBox()
        self.trans_from.addItems(["auto", "zh", "en", "ja"])
        self.trans_to = QComboBox()
        self.trans_to.addItems(["zh", "en", "ja"])
        self.trans_to.setCurrentText("zh")
        row_tr.addWidget(QLabel("原文"))
        row_tr.addWidget(self.trans_from)
        row_tr.addWidget(QLabel("译成"))
        row_tr.addWidget(self.trans_to)
        self.add_run_button(row_tr, "翻译字幕", self.run_translate)
        row_tr.addStretch(1)
        v.addLayout(row_tr)
        self._sub_log, self._sub_out = self.output_block(v)
        v.addWidget(QLabel("视频会自动抽取音轨；字幕输出到 桌面\\音频\\文字稿。"))
        return w

    def run_subtitle(self):
        if not self.require(self.sub_file.path(), "音频或视频"):
            return
        self.start_task(self.backend.subtitle,
                        (self.sub_file.path(), self.sub_model.currentText(),
                         self.sub_lang.currentText(), self.sub_fmt.text().strip()),
                        self._sub_log, self._sub_out)

    def run_translate(self):
        if not self.require(self.trans_file.path(), "字幕或文本"):
            return
        self.start_task(self.backend.translate,
                        (self.trans_file.path(), self.trans_from.currentText(),
                         self.trans_to.currentText()),
                        self._sub_log, self._sub_out)

    def tab_tools(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.tool_audio = PathRow("输入音频", "audio")
        v.addWidget(self.tool_audio)
        row = QHBoxLayout()
        self.add_run_button(row, "人声/伴奏分离", self.run_split)
        self.add_run_button(row, "降噪", self.run_denoise)
        self.add_run_button(row, "音频超分", self.run_sr)
        v.addLayout(row)
        row2 = QHBoxLayout()
        self.enhance = QCheckBox("降噪后做生成式增强（更慢，可能改音色）")
        self.steps = QSpinBox()
        self.steps.setRange(10, 100)
        self.steps.setValue(50)
        self.steps.setSingleStep(5)
        row2.addWidget(self.enhance, 1)
        row2.addWidget(QLabel("AudioSR 步数"))
        row2.addWidget(self.steps)
        v.addLayout(row2)
        self._tool_log, self._tool_out = self.output_block(v)
        v.addWidget(QLabel("分离输出 vocals / instrumental；超分输出 48kHz。"))
        return w

    def run_split(self):
        if not self.require(self.tool_audio.path(), "音频"):
            return
        self.start_task(self.backend.split, (self.tool_audio.path(),), self._tool_log, self._tool_out)

    def run_denoise(self):
        if not self.require(self.tool_audio.path(), "音频"):
            return
        self.start_task(self.backend.denoise,
                        (self.tool_audio.path(), self.enhance.isChecked()),
                        self._tool_log, self._tool_out)

    def run_sr(self):
        if not self.require(self.tool_audio.path(), "音频"):
            return
        self.start_task(self.backend.sr,
                        (self.tool_audio.path(), self.steps.value()),
                        self._tool_log, self._tool_out)

    def tab_clone(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.clone_ref = PathRow("参考人声（5–30 秒）", "audio")
        self.clone_ref.edit.textChanged.connect(lambda: self._preview_path(self.clone_ref.path()))
        v.addWidget(self.clone_ref)
        self.clone_text = QPlainTextEdit()
        self.clone_text.setPlaceholderText("要克隆朗读的文本")
        self.clone_text.setMinimumHeight(120)
        v.addWidget(QLabel("朗读文本"))
        v.addWidget(self.clone_text)
        row = QHBoxLayout()
        self.clone_lang = QComboBox()
        self.clone_lang.addItems(["zh", "en", "ja", "ko"])
        row.addWidget(QLabel("语言")); row.addWidget(self.clone_lang)
        self.clone_engine = QComboBox()
        self.clone_engine.addItem("F5 克隆（推荐）", "f5")
        self.clone_engine.addItem("Chatterbox 克隆", "chatterbox")
        row.addWidget(QLabel("引擎")); row.addWidget(self.clone_engine, 1)
        v.addLayout(row)
        row2 = QHBoxLayout()
        self.clone_speed = QDoubleSpinBox()
        self.clone_speed.setRange(0.5, 2.0)
        self.clone_speed.setSingleStep(0.05)
        self.clone_speed.setDecimals(2)
        self.clone_speed.setValue(1.0)
        self.clone_speed.setSuffix(" x")
        self.clone_pause = QSpinBox()
        self.clone_pause.setRange(0, 3000)
        self.clone_pause.setSingleStep(50)
        self.clone_pause.setValue(200)
        self.clone_pause.setSuffix(" ms")
        row2.addWidget(QLabel("语速")); row2.addWidget(self.clone_speed)
        row2.addWidget(QLabel("句间停顿")); row2.addWidget(self.clone_pause, 1)
        self.add_run_button(row2, "克隆配音", self.run_clone)
        v.addLayout(row2)
        self._clone_log, self._clone_out = self.output_block(v)
        v.addWidget(QLabel("固定音色 TTS（Kokoro）"))
        self.tts_text = QPlainTextEdit()
        self.tts_text.setPlaceholderText("要合成的文本")
        self.tts_text.setMinimumHeight(70)
        v.addWidget(self.tts_text)
        row2 = QHBoxLayout()
        self.tts_voice = QComboBox()
        self.tts_voice.addItems(["zf_001", "zf_002", "zf_003", "zm_009", "zm_010"])
        row2.addWidget(QLabel("音色")); row2.addWidget(self.tts_voice, 1)
        self.add_run_button(row2, "合成", self.run_tts)
        v.addLayout(row2)
        return w

    def run_clone(self):
        if not self.require(self.clone_ref.path(), "参考音频"):
            return
        text = self.clone_text.toPlainText()
        if not self.require_text(text, "朗读文本"):
            return
        self.start_task(self.backend.clone,
                        (self.clone_ref.path(), text, self.clone_lang.currentText(),
                         self.clone_speed.value(), self.clone_pause.value(),
                         self.clone_engine.currentData()),
                        self._clone_log, self._clone_out)

    def run_tts(self):
        text = self.tts_text.toPlainText()
        if not self.require_text(text, "TTS 文本"):
            return
        self.start_task(self.backend.tts,
                        (text, self.tts_voice.currentText()),
                        self._clone_log, self._clone_out)

    def tab_music(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.music_tags = QLineEdit(
            "Chinese folk pop, guzheng and bamboo flute, warm female vocal, mid tempo, clean mix")
        v.addWidget(QLabel("风格 tags（英文更稳）")); v.addWidget(self.music_tags)
        self.music_lyrics = QPlainTextEdit(
            "[verse]\n春风吹过山岗\n桃花开满了村庄\n[chorus]\n一路向前走啊\n把歌儿唱到天亮")
        self.music_lyrics.setMinimumHeight(100)
        v.addWidget(QLabel("歌词（留空则纯音乐）")); v.addWidget(self.music_lyrics)
        row = QHBoxLayout()
        self.music_dur = QSpinBox(); self.music_dur.setRange(15, 120); self.music_dur.setValue(30); self.music_dur.setSuffix(" 秒")
        self.music_bpm = QSpinBox(); self.music_bpm.setRange(60, 180); self.music_bpm.setValue(90)
        self.music_steps = QSpinBox(); self.music_steps.setRange(4, 16); self.music_steps.setValue(8)
        self.music_seed = QSpinBox(); self.music_seed.setRange(0, 2147483647); self.music_seed.setValue(20261025)
        for label, widget in [("时长", self.music_dur), ("BPM", self.music_bpm), ("步数", self.music_steps), ("Seed", self.music_seed)]:
            row.addWidget(QLabel(label)); row.addWidget(widget)
        v.addLayout(row)
        self.add_run_button(v, "生成音乐", self.run_music)
        self._music_log, self._music_out = self.output_block(v)
        v.addWidget(QLabel("实验性：ACE-Step 1.5 XL，通过 ComfyUI 生成；30–60 秒较稳。"))
        return w

    def run_music(self):
        self.start_task(self.backend.music,
                        (self.music_tags.text(), self.music_lyrics.toPlainText(),
                         self.music_dur.value(), self.music_bpm.value(),
                         self.music_steps.value(), self.music_seed.value()),
                        self._music_log, self._music_out)

    def _section_label(self, text):
        lab = QLabel(text)
        lab.setObjectName("sectionLabel")
        lab.setStyleSheet("color:#8fb6e8;font-weight:700;font-size:12pt;margin-top:6px;")
        return lab

    def tab_video_dub(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.addWidget(self._section_label("① 视频与音色"))
        self.dub_video = PathRow("视频", "video")
        self.dub_video.edit.textChanged.connect(lambda: self._preview_path(self.dub_video.path()))
        v.addWidget(self.dub_video)

        row_fx = QHBoxLayout()
        self.voice_pitch = QDoubleSpinBox()
        self.voice_pitch.setRange(-12.0, 12.0)
        self.voice_pitch.setSingleStep(0.5)
        self.voice_pitch.setDecimals(1)
        self.voice_pitch.setValue(0.0)
        self.voice_pitch.setSuffix(" 半音")
        self.voice_formant = QComboBox()
        self.voice_formant.addItem("保留共振峰（自然）", "preserved")
        self.voice_formant.addItem("共振峰跟随音调", "shifted")
        self.voice_tone = QComboBox()
        self.voice_tone.addItem("原始音色", "original")
        self.voice_tone.addItem("更明亮", "bright")
        self.voice_tone.addItem("更低沉", "warm")
        row_fx.addWidget(QLabel("音调"))
        row_fx.addWidget(self.voice_pitch)
        row_fx.addWidget(QLabel("共振峰"))
        row_fx.addWidget(self.voice_formant, 1)
        row_fx.addWidget(QLabel("音色"))
        row_fx.addWidget(self.voice_tone, 1)
        v.addLayout(row_fx)

        v.addWidget(self._section_label("② 引擎与声音库角色"))
        row_engine = QHBoxLayout()
        self.dub_engine = QComboBox()
        self.dub_engine.addItem("自动（有参考/声音库→F5；无参考→Qwen 0.6B）", "auto")
        self.dub_engine.addItem("Kokoro 固定音色", "kokoro")
        self.dub_engine.addItem("Chatterbox 参考克隆", "chatterbox")
        self.dub_engine.addItem("CosyVoice2 风格/音色", "cosyvoice")
        self.dub_engine.addItem("Kokoro → Seed-VC 变声", "seedvc")
        self.dub_engine.addItem("CosyVoice2 → Seed-VC", "cosyvoice+seedvc")
        self.dub_engine.addItem("F5 声音克隆（参考音/声音库）", "f5")
        row_engine.addWidget(QLabel("配音引擎"))
        row_engine.addWidget(self.dub_engine, 1)
        v.addLayout(row_engine)

        row_lib = QHBoxLayout()
        row_lib.addWidget(QLabel("声音库角色"))
        self.dub_voice_profile = QComboBox()
        self.dub_voice_profile.setToolTip("选中后自动用该角色的参考音做 F5 克隆；不选则按引擎默认")
        row_lib.addWidget(self.dub_voice_profile, 1)
        btn_reload_voices = QPushButton("刷新")
        btn_reload_voices.setFixedWidth(60)
        btn_reload_voices.clicked.connect(self.reload_voice_profiles)
        row_lib.addWidget(btn_reload_voices)
        v.addLayout(row_lib)
        self.reload_voice_profiles()

        v.addWidget(self._section_label("③ 旁白内容"))
        mode_row = QHBoxLayout()
        mode_row.setSpacing(8)
        self.mode_prompt_btn = QPushButton("提示词自动配音")
        self.mode_manual_btn = QPushButton("手动台词（精确控制）")
        self._mode_group = QButtonGroup(self)
        for b in (self.mode_prompt_btn, self.mode_manual_btn):
            b.setCheckable(True)
            self._mode_group.addButton(b)
            mode_row.addWidget(b)
        self.mode_prompt_btn.setChecked(True)
        self.mode_prompt_btn.clicked.connect(lambda: self._set_dub_mode("prompt"))
        self.mode_manual_btn.clicked.connect(lambda: self._set_dub_mode("manual"))
        mode_row.addStretch(1)
        v.addLayout(mode_row)

        self.pd_hint = QLabel("提示词自动配音（静音视频可用：Qwen 写旁白 + 自动音色/语速 + 字幕）")
        v.addWidget(self.pd_hint)
        self.pd_prompt = QPlainTextEdit()
        self.pd_prompt.setPlaceholderText(
            "例如：用沉稳男声介绍这台笔记本的性能，语气专业，约 30 秒；字幕放底部。")
        self.pd_prompt.setMinimumHeight(110)
        v.addWidget(self.pd_prompt)
        self.output_section = self._section_label("④ 输出选项")
        v.addWidget(self.output_section)
        self.pd_actions = QWidget()
        row_pd = QHBoxLayout(self.pd_actions)
        row_pd.setContentsMargins(0, 0, 0, 0)
        row_pd.setSpacing(10)
        self.pd_burn = QCheckBox("把旁白字幕烧录到视频")
        self.pd_keep = QCheckBox("保留原视频声音（25% 混音）")
        row_pd.addWidget(self.pd_burn, 1)
        row_pd.addWidget(self.pd_keep)
        self.add_run_button(row_pd, "提示词自动配音", self.run_prompt_dub)
        v.addWidget(self.pd_actions)

        self.manual_section = self._section_label("④ 手动台词（精确控制）")
        v.addWidget(self.manual_section)
        self.manual_box = QWidget()
        mb = QVBoxLayout(self.manual_box)
        mb.setContentsMargins(0, 0, 0, 0)
        mb.setSpacing(10)
        mb.addWidget(QLabel("填写台词 + 参考人声 → 点「手动台词配音」；有参考音时走 F5"))
        self.dub_text = QPlainTextEdit()
        self.dub_text.setPlaceholderText("手动配音文本")
        self.dub_text.setMinimumHeight(100)
        mb.addWidget(self.dub_text)
        row = QHBoxLayout()
        self.dub_voice = QComboBox()
        self.dub_voice.addItems(["zf_001", "zf_002", "zf_003", "zm_009", "zm_010"])
        self.dub_lang = QComboBox(); self.dub_lang.addItems(["zh", "en", "ja", "ko"])
        row.addWidget(QLabel("Kokoro 音色")); row.addWidget(self.dub_voice, 1)
        row.addWidget(QLabel("克隆语言")); row.addWidget(self.dub_lang)
        mb.addLayout(row)
        self.dub_ref = PathRow("参考人声（可选：填了走 F5 克隆）", "audio")
        self.dub_ref.edit.textChanged.connect(lambda: self._preview_path(self.dub_ref.path()))
        mb.addWidget(self.dub_ref)
        self.add_run_button(mb, "手动台词配音", self.run_video_dub)
        v.addWidget(self.manual_box)
        self._set_dub_mode("prompt")

        self.dub_preview = QLabel("")
        self.dub_preview.setWordWrap(True)
        v.addWidget(self.dub_preview)
        self._dub_log, self._dub_out = self.output_block(v)
        v.addWidget(QLabel("只替换/添加音轨，不做口型同步；提示词模式可选烧录字幕。"))
        return w

    def _set_dub_mode(self, mode):
        prompt = mode == "prompt"
        self.mode_prompt_btn.setChecked(prompt)
        self.mode_manual_btn.setChecked(not prompt)
        for w in (self.pd_hint, self.pd_prompt, self.output_section, self.pd_actions):
            w.setVisible(prompt)
        for w in (self.manual_section, self.manual_box):
            w.setVisible(not prompt)

    def reload_voice_profiles(self):
        if not hasattr(self, "dub_voice_profile"):
            return
        current = self.dub_voice_profile.currentData()
        self.dub_voice_profile.blockSignals(True)
        self.dub_voice_profile.clear()
        self.dub_voice_profile.addItem("（不使用声音库，按引擎默认）", "")
        try:
            profiles = self.backend.voice_profiles()
        except Exception:
            profiles = []
        for p in profiles:
            label = "{} / {}（{}）".format(
                p.get("game", ""), p.get("character", ""), p.get("id", ""))
            self.dub_voice_profile.addItem(label, p.get("id", ""))
        if current:
            idx = self.dub_voice_profile.findData(current)
            if idx >= 0:
                self.dub_voice_profile.setCurrentIndex(idx)
        self.dub_voice_profile.blockSignals(False)

    def run_prompt_dub(self):
        if not self.require(self.dub_video.path(), "视频"):
            return
        prompt = self.pd_prompt.toPlainText().strip()
        if not prompt:
            QMessageBox.warning(self, "缺少提示词", "请描述想要的旁白内容和音色风格。")
            return
        engine = self.dub_engine.currentData()
        if engine in ("seedvc", "cosyvoice+seedvc") and not self.dub_ref.path():
            QMessageBox.warning(self, "缺少参考音频", "Seed-VC 需要目标音色参考音频。")
            return
        profile_id = self.dub_voice_profile.currentData() if hasattr(self, "dub_voice_profile") else ""
        profile = None
        if profile_id:
            try:
                profile = next((p for p in self.backend.voice_profiles() if p.get("id") == profile_id), None)
            except Exception:
                profile = None
        voice_query = ""
        if profile:
            voice_query = str(profile.get("character") or profile.get("id") or "")
        self.start_task(self.backend.prompt_dub,
                        (self.dub_video.path(), prompt, self.dub_ref.path(),
                         self.dub_lang.currentText(), self.pd_burn.isChecked(),
                         self.voice_pitch.value(),
                         self.voice_formant.currentData(),
                         self.voice_tone.currentData(),
                         self.dub_engine.currentData(),
                         "",
                         voice_query,
                         self.pd_keep.isChecked() if hasattr(self, "pd_keep") else False),
                        self._dub_log, self._dub_out, self.dub_preview)


    def run_video_dub(self):
        if not self.require(self.dub_video.path(), "视频"):
            return
        text = self.dub_text.toPlainText()
        if not self.require_text(text, "配音文本"):
            return
        ref = self.dub_ref.path()
        self.start_task(self.backend.video_dub,
                        (self.dub_video.path(), text, self.dub_voice.currentText(),
                         ref, self.dub_lang.currentText(), self.voice_pitch.value(),
                         self.voice_formant.currentData(), self.voice_tone.currentData()),
                        self._dub_log, self._dub_out, self.dub_preview)

    def tab_collect(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.collect_game = FolderRow("游戏安装目录（鸣潮 / Steam / 任意 UE、Unity 游戏）")
        v.addWidget(self.collect_game)
        row_scan = QHBoxLayout()
        self.add_run_button(row_scan, "扫描游戏", self.run_scan_game)
        v.addLayout(row_scan)

        v.addWidget(QLabel("网页视频转音频（公开、非 DRM 页面；下载后自动提取 WAV）"))
        self.collect_url = QLineEdit()
        self.collect_url.setPlaceholderText("粘贴网页视频 URL，例如 B 站/YouTube 公开视频")
        v.addWidget(self.collect_url)
        self.collect_out = FolderRow("输出目录（留空用 游戏语音采集\\网页音频）")
        v.addWidget(self.collect_out)
        row_web = QHBoxLayout()
        self.add_run_button(row_web, "网页视频转音频", self.run_web_audio)
        v.addLayout(row_web)

        row_open = QHBoxLayout()
        for label, action in (("打开 FModel", "fmodel"), ("打开 AssetRipper", "assetripper"),
                              ("打开 AnimeWwise", "anime"), ("打开 OBS", "obs")):
            btn = QPushButton(label)
            btn.setProperty("secondary", True)
            btn.clicked.connect(lambda _=False, a=action: self.backend.open_collector(a))
            row_open.addWidget(btn)
        v.addLayout(row_open)
        v.addWidget(QLabel("支持：UE/鸣潮 → FModel；Unity → AssetRipper；HoYo/Wwise → AnimeWwise；网页 → yt-dlp；其余 → OBS。"))
        self._collect_log, self._collect_output = self.output_block(v)
        return w

    def run_scan_game(self):
        path = self.collect_game.path()
        if not path:
            QMessageBox.warning(self, "缺少目录", "请选择游戏安装目录。")
            return
        self.start_task(self.backend.scan_game, (path,),
                        self._collect_log, self._collect_output)

    def run_web_audio(self):
        url = self.collect_url.text().strip()
        if not url:
            QMessageBox.warning(self, "缺少 URL", "请粘贴网页视频地址。")
            return
        self.start_task(self.backend.web_audio,
                        (url, self.collect_out.path()),
                        self._collect_log, self._collect_output)

    def tab_voice_library(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.addWidget(QLabel("声音库：搜索已克隆的角色，选中后直接生成台词"))
        self.voice_search = QLineEdit()
        self.voice_search.setPlaceholderText("输入角色名，例如：阮梅 / 阮·梅 / Ruan Mei")
        self.voice_search.textChanged.connect(self.refresh_voice_list)
        v.addWidget(self.voice_search)
        self.voice_list = QListWidget()
        self.voice_list.setMinimumHeight(120)
        self.voice_list.itemSelectionChanged.connect(self.on_voice_selected)
        v.addWidget(self.voice_list)
        self.voice_meta = QLabel("")
        self.voice_meta.setWordWrap(True)
        v.addWidget(self.voice_meta)
        self.voice_text = QPlainTextEdit()
        self.voice_text.setPlaceholderText("要生成的台词")
        self.voice_text.setMinimumHeight(80)
        v.addWidget(self.voice_text)
        v.addWidget(QLabel("语气提示词（可自由描述，不只是预设）"))
        self.voice_tone_preset = QComboBox()
        for label, prompt in (
            ("自定义（在下方写）", ""),
            ("平静自然", "用平静、自然、放松的语气说这句话"),
            ("清冷疏离", "用清冷、疏离、克制的语气说这句话，语速偏慢"),
            ("温柔亲切", "用温柔、亲切、带笑意的语气说这句话"),
            ("悲伤低落", "用悲伤、低落、略带哽咽的语气说这句话"),
            ("兴奋激动", "用兴奋、激动、明亮的语气说这句话"),
            ("严厉压迫", "用严厉、低沉、有压迫感的语气说这句话"),
            ("疲惫慵懒", "用疲惫、慵懒、气声较多的语气说这句话"),
            ("新闻播报", "用专业、清晰、新闻播报的语气说这句话"),
        ):
            self.voice_tone_preset.addItem(label, prompt)
        self.voice_tone_preset.currentIndexChanged.connect(self.apply_voice_tone_preset)
        v.addWidget(self.voice_tone_preset)
        self.voice_instruct = QPlainTextEdit()
        self.voice_instruct.setPlaceholderText(
            "例如：用 40 岁低沉沙哑、带一点疲惫感的语气，语速慢，像深夜电台")
        self.voice_instruct.setMinimumHeight(55)
        v.addWidget(self.voice_instruct)
        self.add_run_button(v, "生成语音（CosyVoice，可带语气）", self.run_voice_generate)
        row_f5 = QHBoxLayout()
        self.voice_speed = QDoubleSpinBox()
        self.voice_speed.setRange(0.5, 2.0)
        self.voice_speed.setSingleStep(0.05)
        self.voice_speed.setDecimals(2)
        self.voice_speed.setValue(1.0)
        self.voice_speed.setSuffix(" x")
        self.voice_pause = QSpinBox()
        self.voice_pause.setRange(0, 3000)
        self.voice_pause.setSingleStep(50)
        self.voice_pause.setValue(200)
        self.voice_pause.setSuffix(" ms")
        row_f5.addWidget(QLabel("语速")); row_f5.addWidget(self.voice_speed)
        row_f5.addWidget(QLabel("句间停顿")); row_f5.addWidget(self.voice_pause, 1)
        self.add_run_button(row_f5, "F5 纯音频（更像）", self.run_voice_generate_f5)
        v.addLayout(row_f5)
        self._voice_log, self._voice_out = self.output_block(v)
        self.refresh_voice_list()
        return w

    def apply_voice_tone_preset(self):
        prompt = self.voice_tone_preset.currentData()
        if prompt:
            self.voice_instruct.setPlainText(prompt)

    def refresh_voice_list(self):
        q = self.voice_search.text().strip() if hasattr(self, "voice_search") else ""
        profiles = self.backend.search_voices(q)
        self.voice_list.clear()
        for p in profiles:
            item = QListWidgetItem(
                f"{p.get('game', '')} · {p.get('character', '')}  "
                f"({p.get('samples', 0)} 条样本)")
            item.setData(Qt.UserRole, p.get("id"))
            item.setToolTip(p.get("reference", ""))
            self.voice_list.addItem(item)
        if self.voice_list.count():
            self.voice_list.setCurrentRow(0)
        else:
            self.voice_meta.setText("没有匹配的角色；先在 C:\\音频素材 放入参考音频并在 voices.json 登记。")

    def on_voice_selected(self):
        item = self.voice_list.currentItem()
        if not item:
            return
        pid = item.data(Qt.UserRole)
        profile = next((p for p in self.backend.voice_profiles() if p.get("id") == pid), None)
        if not profile:
            return
        self.voice_meta.setText(
            f"来源：{profile.get('source', '')}\n参考：{profile.get('reference', '')}\n"
            f"标签：{'、'.join(profile.get('tags', []) or [])}")
        try:
            self.inspector.show_media(str(profile.get("reference") or ""))
        except Exception:
            pass

    def run_voice_generate(self):
        item = self.voice_list.currentItem()
        if not item:
            QMessageBox.warning(self, "未选择角色", "请先在搜索结果里选一个角色。")
            return
        text = self.voice_text.toPlainText().strip()
        if not text:
            QMessageBox.warning(self, "缺少台词", "请输入要生成的台词。")
            return
        self.start_task(self.backend.generate_voice,
                        (item.data(Qt.UserRole), text, self.voice_instruct.toPlainText().strip()),
                        self._voice_log, self._voice_out)

    def run_voice_generate_f5(self):
        item = self.voice_list.currentItem()
        if not item:
            QMessageBox.warning(self, "未选择角色", "请先在搜索结果里选一个角色。")
            return
        profile = next((p for p in self.backend.voice_profiles()
                        if p.get("id") == item.data(Qt.UserRole)), None)
        if not profile:
            QMessageBox.warning(self, "找不到角色", "声音库档案缺少参考音。")
            return
        text = self.voice_text.toPlainText().strip()
        if not text:
            QMessageBox.warning(self, "缺少台词", "请输入要生成的台词。")
            return
        self.start_task(self.backend.clone,
                        (profile["reference"], text, "zh",
                         self.voice_speed.value(), self.voice_pause.value(), "f5"),
                        self._voice_log, self._voice_out)

    def tab_advanced(self):
        w = QWidget()
        outer = QVBoxLayout(w)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        body = QWidget()
        v = QVBoxLayout(body)
        scroll.setWidget(body)
        outer.addWidget(scroll)

        adv_audio = PathRow("音频（分轨/降噪共用）", "audio")
        v.addWidget(adv_audio)
        row = QHBoxLayout()
        self.add_run_button(row, "MelBand 分轨", lambda: self.run_adv(
            "mr", adv_audio.path()))
        self.add_run_button(row, "DFN3 降噪", lambda: self.run_adv(
            "dfn", adv_audio.path()))
        v.addLayout(row)

        v.addWidget(QLabel("母带匹配（Matchering：把目标音频匹配到参考歌曲的响度/音色）"))
        self.master_target = PathRow("待处理音频", "audio")
        self.master_ref = PathRow("参考音乐", "audio")
        v.addWidget(self.master_target)
        v.addWidget(self.master_ref)
        self.add_run_button(v, "母带匹配", self.run_mastering)

        v.addWidget(QLabel("字幕对齐（音频 + 文稿 → 词级 SRT）"))
        self.align_audio = PathRow("音频", "audio")
        v.addWidget(self.align_audio)
        self.align_text = QPlainTextEdit()
        self.align_text.setPlaceholderText("粘贴文稿")
        self.align_text.setMinimumHeight(70)
        v.addWidget(self.align_text)
        self.align_txt = PathRow("或上传 txt", "text")
        v.addWidget(self.align_txt)
        row2 = QHBoxLayout()
        self.align_lang = QComboBox(); self.align_lang.addItems(["zh", "en", "ja"])
        row2.addWidget(QLabel("语言")); row2.addWidget(self.align_lang, 1)
        self.add_run_button(row2, "对齐字幕", self.run_align)
        v.addLayout(row2)

        v.addWidget(QLabel("口型同步（MuseTalk 1.5，当前环境未完成）"))
        self.lip_video = PathRow("视频", "video")
        self.lip_audio = PathRow("配音音频", "audio")
        v.addWidget(self.lip_video); v.addWidget(self.lip_audio)
        self.add_run_button(v, "生成口型视频", self.run_lipsync)
        self.adv_preview = QLabel(""); self.adv_preview.setWordWrap(True)
        v.addWidget(self.adv_preview)
        self._adv_log, self._adv_out = self.output_block(v)
        self._adv_audio = adv_audio
        return w

    def run_adv(self, kind, audio):
        if not self.require(audio, "音频"):
            return
        fn = self.backend.mr if kind == "mr" else self.backend.dfn
        self.start_task(fn, (audio,), self._adv_log, self._adv_out)

    def run_mastering(self):
        if not self.require(self.master_target.path(), "待处理音频"):
            return
        if not self.require(self.master_ref.path(), "参考音乐"):
            return
        self.start_task(self.backend.mastering,
                        (self.master_target.path(), self.master_ref.path()),
                        self._adv_log, self._adv_out)

    def run_align(self):
        if not self.require(self.align_audio.path(), "音频"):
            return
        text = self.align_text.toPlainText()
        txt_file = self.align_txt.path()
        if not text.strip() and not txt_file:
            QMessageBox.warning(self, "缺少文稿", "请粘贴文稿或选择 txt。")
            return
        self.start_task(self.backend.align,
                        (self.align_audio.path(), text, txt_file, self.align_lang.currentText()),
                        self._adv_log, self._adv_out)

    def run_lipsync(self):
        if not self.require(self.lip_video.path(), "视频") or not self.require(self.lip_audio.path(), "配音音频"):
            return
        self.start_task(self.backend.lipsync,
                        (self.lip_video.path(), self.lip_audio.path()),
                        self._adv_log, self._adv_out, self.adv_preview)

    def tab_diar_midi(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.dm_audio = PathRow("输入音频", "audio")
        v.addWidget(self.dm_audio)
        row = QHBoxLayout()
        self.add_run_button(row, "说话人分离", self.run_diarize)
        self.add_run_button(row, "转 MIDI", self.run_midi)
        v.addLayout(row)
        self._dm_log, self._dm_out = self.output_block(v)
        v.addWidget(QLabel("说话人分离目前按 2 人模型；MIDI 适合旋律清晰的片段。"))
        return w

    def run_diarize(self):
        if not self.require(self.dm_audio.path(), "音频"):
            return
        self.start_task(self.backend.diarize, (self.dm_audio.path(),), self._dm_log, self._dm_out)

    def run_midi(self):
        if not self.require(self.dm_audio.path(), "音频"):
            return
        self.start_task(self.backend.midi, (self.dm_audio.path(),), self._dm_log, self._dm_out)

    def tab_status(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.status_text = QPlainTextEdit()
        self.status_text.setReadOnly(True)
        self.status_text.setFont(QFont("Consolas", 9))
        v.addWidget(self.status_text, 1)
        row = QHBoxLayout()
        btn = QPushButton("刷新状态")
        btn.clicked.connect(self.refresh_status)
        row.addWidget(btn)
        row.addStretch(1)
        v.addLayout(row)
        self.refresh_status()
        return w

    def refresh_status(self):
        try:
            self.status_text.setPlainText(self.backend.status())
        except Exception as exc:
            self.status_text.setPlainText(str(exc))

    # ---------- idle / close ----------

    def eventFilter(self, obj, event):
        if event.type() in (QEvent.MouseButtonPress, QEvent.KeyPress, QEvent.MouseMove, QEvent.Wheel):
            self.backend.touch()
        return super().eventFilter(obj, event)

    def check_idle(self):
        if self.backend.is_busy():
            return
        if getattr(self, "batch_watch", None) is not None and self.batch_watch.isChecked():
            return
        if time.time() - self.backend.last_activity >= IDLE_SECONDS:
            self.close()

    def check_quit_flag(self):
        if QUIT_FLAG.exists():
            try: QUIT_FLAG.unlink()
            except OSError: pass
            self.close()

    def closeEvent(self, event):
        if self.backend.is_busy():
            QMessageBox.warning(self, "任务运行中", "任务完成前不能退出；特殊情况请用桌面的「音频工作台 - 强制退出」。")
            event.ignore()
            return
        if self.worker and self.worker.isRunning():
            self.worker.wait(2000)
        event.accept()
        QApplication.quit()


def apply_dark(app):
    app.setStyle("Fusion")
    pal = QPalette()
    pal.setColor(QPalette.Window, QColor(24, 24, 28))
    pal.setColor(QPalette.WindowText, QColor(230, 230, 235))
    pal.setColor(QPalette.Base, QColor(18, 18, 22))
    pal.setColor(QPalette.AlternateBase, QColor(30, 30, 36))
    pal.setColor(QPalette.ToolTipBase, QColor(40, 40, 46))
    pal.setColor(QPalette.ToolTipText, QColor(240, 240, 245))
    pal.setColor(QPalette.Text, QColor(230, 230, 235))
    pal.setColor(QPalette.Button, QColor(40, 42, 50))
    pal.setColor(QPalette.ButtonText, QColor(235, 235, 240))
    pal.setColor(QPalette.Highlight, QColor(64, 105, 180))
    pal.setColor(QPalette.HighlightedText, Qt.white)
    app.setPalette(pal)
    app.setFont(QFont("Microsoft YaHei UI", 10))
    app.setStyleSheet(APP_QSS)


def main():
    app = QApplication(sys.argv)
    apply_dark(app)
    window = MainWindow()
    if "--smoke" in sys.argv:
        window.show()
        QTimer.singleShot(1500, app.quit)
    else:
        window.showMaximized()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

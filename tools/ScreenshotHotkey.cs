// ScreenshotHotkey —— Ctrl+Alt+Insert 截取主屏（纯托盘 + 消息窗口，零可见窗口）
//
// 设计：
//   - 用 RegisterHotKey 注册 Ctrl+Alt+Insert，不做键盘映射
//   - 单独按 Insert / 其他 Insert 组合完全不受影响
//   - 只截主屏（Screen.PrimaryScreen），避开 800x600 回音壁屏
//   - 保存到 图片\Screenshots，同时复制到剪贴板
//   - 截图后：白色快门闪 + 右下角缩略图提示（手机截图效果）
//   - 2026-10-25：不再创建可见 Form，改用 NativeWindow 消息窗口 + 托盘图标
//     （之前后台那个小窗口被关掉，程序就退出，热键随之失效）
//
// 编译：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize+ ^
//     /r:System.Windows.Forms.dll /r:System.Drawing.dll ^
//     /out:ScreenshotHotkey.exe ScreenshotHotkey.cs
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// 截图后闪一下的遮罩（tool window，不抢焦点）
internal sealed class OverlayForm : Form
{
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_NOACTIVATE = 0x08000000;

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }
}

// 截图逻辑（与窗口无关，便于复用）
internal static class Shot
{
    public static readonly string LogPath = @"D:\tools\win-layout\screenshot.log";
    public static readonly string ShotDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Screenshots");

    private static Form flashForm;
    private static Form thumbForm;
    private static System.Windows.Forms.Timer flashTimer;
    private static System.Windows.Forms.Timer thumbTimer;
    private static SoundPlayer shutterPlayer;

    public static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(@"D:\tools\win-layout");
            File.AppendAllText(LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine,
                Encoding.UTF8);
        }
        catch { }
    }

    public static void CapturePrimary()
    {
        try
        {
            Screen screen = Screen.PrimaryScreen;
            if (screen == null)
            {
                Log("capture failed: no primary screen");
                return;
            }
            Rectangle bounds = screen.Bounds;
            Directory.CreateDirectory(ShotDir);
            string name = "Screenshot_" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss-fff") + ".png";
            string path = Path.Combine(ShotDir, name);
            bool copied = false;

            using (var bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb))
            using (var g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
                bmp.Save(path, ImageFormat.Png);
                try
                {
                    Clipboard.SetImage(bmp);
                    copied = true;
                }
                catch (Exception ex)
                {
                    Log("clipboard failed: " + ex.Message);
                }
            }
            Log("saved " + path + " " + bounds.Width + "x" + bounds.Height + " clipboard=" + copied);
            PlayShutter();
            Flash();
            ShowThumbnail(path, copied);
        }
        catch (Exception ex)
        {
            Log("capture failed: " + ex);
        }
    }

    private static byte[] BuildShutterWav()
    {
        const int rate = 44100;
        const double duration = 0.11;
        int count = (int)(rate * duration);
        int dataSize = count * 2;
        var rng = new Random(12345);

        using (var ms = new MemoryStream(44 + dataSize))
        using (var w = new BinaryWriter(ms))
        {
            w.Write(Encoding.ASCII.GetBytes("RIFF"));
            w.Write(36 + dataSize);
            w.Write(Encoding.ASCII.GetBytes("WAVE"));
            w.Write(Encoding.ASCII.GetBytes("fmt "));
            w.Write(16);
            w.Write((short)1);      // PCM
            w.Write((short)1);      // mono
            w.Write(rate);
            w.Write(rate * 2);      // byte rate
            w.Write((short)2);      // block align
            w.Write((short)16);     // bits
            w.Write(Encoding.ASCII.GetBytes("data"));
            w.Write(dataSize);

            for (int i = 0; i < count; i++)
            {
                double t = (double)i / rate;
                double env = 0.0;
                if (t < 0.030) env += Math.Exp(-t * 110.0);
                if (t >= 0.045 && t < 0.080) env += Math.Exp(-(t - 0.045) * 120.0) * 0.8;
                double noise = rng.NextDouble() * 2.0 - 1.0;
                short sample = (short)(noise * env * 0.30 * short.MaxValue);
                w.Write(sample);
            }
            w.Flush();
            return ms.ToArray();
        }
    }

    private static void PlayShutter()
    {
        try
        {
            if (shutterPlayer == null)
            {
                shutterPlayer = new SoundPlayer(new MemoryStream(BuildShutterWav()));
                shutterPlayer.Load();
            }
            shutterPlayer.Play();
        }
        catch (Exception ex)
        {
            Log("shutter sound failed: " + ex.Message);
        }
    }

    private static void Flash()
    {
        try
        {
            if (flashTimer != null)
            {
                flashTimer.Stop();
                flashTimer.Dispose();
                flashTimer = null;
            }
            if (flashForm != null)
            {
                flashForm.Close();
                flashForm.Dispose();
                flashForm = null;
            }

            Screen screen = Screen.PrimaryScreen;
            if (screen == null) return;

            var form = new OverlayForm();
            form.FormBorderStyle = FormBorderStyle.None;
            form.StartPosition = FormStartPosition.Manual;
            form.Bounds = screen.Bounds;
            form.BackColor = Color.Black;
            form.Opacity = 0.72;
            form.TopMost = true;
            form.ShowInTaskbar = false;

            var frame = new Panel();
            frame.Dock = DockStyle.Fill;
            frame.BackColor = Color.Transparent;
            frame.Paint += (s, e) =>
            {
                using (var pen = new Pen(Color.White, 14))
                {
                    e.Graphics.DrawRectangle(pen, 7, 7, frame.Width - 14, frame.Height - 14);
                }
            };
            form.Controls.Add(frame);
            form.Show();
            flashForm = form;

            flashTimer = new System.Windows.Forms.Timer { Interval = 180 };
            flashTimer.Tick += (s, e) =>
            {
                if (flashTimer != null)
                {
                    flashTimer.Stop();
                    flashTimer.Dispose();
                    flashTimer = null;
                }
                if (flashForm == form)
                {
                    flashForm = null;
                    form.Close();
                    form.Dispose();
                }
            };
            flashTimer.Start();
        }
        catch (Exception ex)
        {
            Log("flash failed: " + ex.Message);
        }
    }

    private static void ShowThumbnail(string path, bool copied)
    {
        try
        {
            if (thumbTimer != null)
            {
                thumbTimer.Stop();
                thumbTimer.Dispose();
                thumbTimer = null;
            }
            if (thumbForm != null)
            {
                thumbForm.Close();
                thumbForm.Dispose();
                thumbForm = null;
            }

            Screen screen = Screen.PrimaryScreen;
            if (screen == null) return;

            Image image = Image.FromFile(path);
            var form = new OverlayForm();
            form.FormBorderStyle = FormBorderStyle.None;
            form.StartPosition = FormStartPosition.Manual;
            form.Size = new Size(460, 350);
            form.BackColor = Color.FromArgb(22, 26, 34);
            form.Opacity = 0.97;
            form.TopMost = true;
            form.ShowInTaskbar = false;

            var picture = new PictureBox();
            picture.Image = image;
            picture.SizeMode = PictureBoxSizeMode.Zoom;
            picture.Bounds = new Rectangle(10, 10, 440, 280);

            var label = new Label();
            label.Text = copied ? "已截图 · 已复制   Ctrl+V 粘贴" : "已截图（剪贴板复制失败）";
            label.ForeColor = Color.White;
            label.BackColor = Color.Transparent;
            label.Font = new Font("Microsoft YaHei UI", 10f, FontStyle.Bold);
            label.TextAlign = ContentAlignment.MiddleCenter;
            label.Bounds = new Rectangle(10, 300, 440, 38);

            form.Controls.Add(picture);
            form.Controls.Add(label);
            form.Paint += (s, e) =>
            {
                using (var pen = new Pen(Color.FromArgb(77, 163, 255), 2))
                {
                    e.Graphics.DrawRectangle(pen, 1, 1, form.Width - 3, form.Height - 3);
                }
            };
            form.FormClosed += (s, e) =>
            {
                if (picture.Image != null)
                {
                    picture.Image.Dispose();
                    picture.Image = null;
                }
            };

            Rectangle work = screen.WorkingArea;
            form.Location = new Point(work.Right - form.Width - 20, work.Bottom - form.Height - 20);
            form.Show();
            thumbForm = form;

            thumbTimer = new System.Windows.Forms.Timer { Interval = 3000 };
            thumbTimer.Tick += (s, e) =>
            {
                if (thumbTimer != null)
                {
                    thumbTimer.Stop();
                    thumbTimer.Dispose();
                    thumbTimer = null;
                }
                if (thumbForm == form)
                {
                    thumbForm = null;
                    form.Close();
                    form.Dispose();
                }
            };
            thumbTimer.Start();
        }
        catch (Exception ex)
        {
            Log("thumbnail failed: " + ex.Message);
        }
    }
}

// 隐藏的消息窗口：只用来接收 WM_HOTKEY，没有界面
internal sealed class HotkeyWindow : NativeWindow
{
    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 0x5343;
    private const uint MOD_ALT = 0x0001;
    private const uint MOD_CONTROL = 0x0002;
    private const uint MOD_NOREPEAT = 0x4000;
    private const uint VK_INSERT = 0x2D;

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private bool registered;
    private NotifyIcon tray;
    private ContextMenuStrip menu;

    public HotkeyWindow()
    {
        CreateHandle(new CreateParams());
        BuildTray();
        registered = RegisterHotKey(Handle, HOTKEY_ID, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_INSERT);
        Shot.Log(registered
            ? "registered Ctrl+Alt+Insert"
            : "REGISTER FAILED (conflict or hotkey already in use), Win32=" + Marshal.GetLastWin32Error());
    }

    private void BuildTray()
    {
        try
        {
            tray = new NotifyIcon();
            tray.Icon = LoadTrayIcon();
            tray.Text = "截图热键 Ctrl+Alt+Insert（双击托盘图标立即截图）";
            tray.Visible = true;

            menu = new ContextMenuStrip();
            var miShot = new ToolStripMenuItem("立即截取主屏");
            miShot.Click += (s, e) => Shot.CapturePrimary();
            var miOpen = new ToolStripMenuItem("打开截图文件夹");
            miOpen.Click += (s, e) =>
            {
                try
                {
                    Directory.CreateDirectory(Shot.ShotDir);
                    System.Diagnostics.Process.Start("explorer.exe", Shot.ShotDir);
                }
                catch (Exception ex) { Shot.Log("open folder failed: " + ex.Message); }
            };
            var miExit = new ToolStripMenuItem("退出（关闭截图热键）");
            miExit.Click += (s, e) =>
            {
                Shot.Log("exit requested from tray menu");
                Shutdown();
            };
            menu.Items.Add(miShot);
            menu.Items.Add(miOpen);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(miExit);
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += (s, e) => Shot.CapturePrimary();
        }
        catch (Exception ex)
        {
            Shot.Log("tray init failed: " + ex.Message);
        }
    }

    // 托盘/exe 图标：优先用同目录 screenshot.ico，取不到就用系统默认
    private static Icon LoadTrayIcon()
    {
        try
        {
            string icoPath = Path.Combine(@"D:\tools\win-layout", "screenshot.ico");
            if (File.Exists(icoPath))
            {
                return new Icon(icoPath, 32, 32);
            }
        }
        catch (Exception ex) { Shot.Log("icon load failed: " + ex.Message); }
        return SystemIcons.Application;
    }

    public void Shutdown()
    {
        try
        {
            if (registered) UnregisterHotKey(Handle, HOTKEY_ID);
            registered = false;
            if (tray != null)
            {
                tray.Visible = false;
                tray.Dispose();
                tray = null;
            }
            if (menu != null) { menu.Dispose(); menu = null; }
            DestroyHandle();
        }
        catch (Exception ex) { Shot.Log("shutdown failed: " + ex.Message); }
        Application.ExitThread();
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID)
        {
            Shot.CapturePrimary();
            return;
        }
        base.WndProc(ref m);
    }
}

internal static class ScreenshotHotkey
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [STAThread]
    private static void Main()
    {
        // 单实例：已经有一个在跑就直接退出，避免热键互相抢
        bool createdNew;
        using (var mutex = new Mutex(true, "Global\\ScreenshotHotkey_SingleInstance", out createdNew))
        {
            if (!createdNew) return;
            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            var win = new HotkeyWindow();
            Application.Run();   // 无窗体消息循环；只有托盘"退出"会结束
            GC.KeepAlive(win);
        }
    }
}

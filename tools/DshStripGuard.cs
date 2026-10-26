// DshStripGuard —— DSH 窗口右侧 154px 防烧屏条
// 行为：DSH 在前台且系统空闲 >= 60 秒时，右侧条变纯黑；任何输入立即恢复。
// 点击穿透，不抢焦点，不影响滚动。
// 编译：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize+ ^
//     /r:System.Windows.Forms.dll /r:System.Drawing.dll ^
//     /out:DshStripGuard.exe DshStripGuard.cs
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal sealed class StripForm : Form
{
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TRANSPARENT = 0x00000020;

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT;
            return cp;
        }
    }
}

internal sealed class DshStripGuardContext : ApplicationContext
{
    private const int STRIP_WIDTH = 154;
    private const int STRIP_HEIGHT = 723;
    private static readonly Color StripColor = Color.FromArgb(0x15, 0x15, 0x17);
    private readonly int idleSeconds;
    private readonly bool force;
    private readonly Timer timer;
    private readonly StripForm overlay;
    private bool isVisible;
    private bool lastShow;
    private DateTime lastLog = DateTime.MinValue;
    private static readonly string LogPath = @"D:\tools\win-layout\dshstripguard.log";

    private static void Log(string text)
    {
        try { File.AppendAllText(LogPath, "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + text + Environment.NewLine); }
        catch { }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("kernel32.dll")]
    private static extern uint GetTickCount();

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    public DshStripGuardContext(int idleSeconds, bool force)
    {
        this.idleSeconds = Math.Max(2, idleSeconds);
        this.force = force;
        overlay = new StripForm();
        overlay.FormBorderStyle = FormBorderStyle.None;
        overlay.StartPosition = FormStartPosition.Manual;
        overlay.BackColor = StripColor;
        overlay.ForeColor = StripColor;
        overlay.TopMost = true;
        overlay.ShowInTaskbar = false;
        overlay.ControlBox = false;
        overlay.MaximizeBox = false;
        overlay.MinimizeBox = false;
        overlay.Text = "DshStripGuard";
        overlay.Hide();

        timer = new Timer();
        timer.Interval = 250;
        timer.Tick += Tick;
        timer.Start();
    }

    private static double IdleSeconds()
    {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) return 0;
        return (GetTickCount() - info.dwTime) / 1000.0;
    }

    private static bool IsDshForeground(out IntPtr hwnd)
    {
        hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return false;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) return false;
        try
        {
            string name = Process.GetProcessById((int)pid).ProcessName;
            return name.IndexOf("DeepSeek Harness", StringComparison.OrdinalIgnoreCase) >= 0;
        }
        catch
        {
            return false;
        }
    }

    private void Tick(object sender, EventArgs e)
    {
        try
        {
            IntPtr hwnd;
            bool dsh = IsDshForeground(out hwnd) && IsWindowVisible(hwnd) && !IsIconic(hwnd);
            bool show = force ? dsh : (dsh && IdleSeconds() >= idleSeconds);
            if ((DateTime.Now - lastLog).TotalSeconds >= 2.0 || show != lastShow)
            {
                lastLog = DateTime.Now;
                lastShow = show;
                Log("dsh=" + dsh + " idle=" + IdleSeconds().ToString("F1") + " show=" + show + " visible=" + isVisible);
            }

            if (show)
            {
                RECT client;
                if (!GetClientRect(hwnd, out client)) { HideOverlay(); return; }
                POINT origin = new POINT();
                if (!ClientToScreen(hwnd, ref origin)) { HideOverlay(); return; }

                Rectangle screen = Screen.FromHandle(hwnd).Bounds;
                int dpi = 96;
                try { uint d = GetDpiForWindow(hwnd); if (d >= 72 && d <= 480) dpi = (int)d; } catch { }
                // 154×723 是逻辑像素；4K@150% 下为 231×1084 物理像素
                int w = (int)Math.Round(STRIP_WIDTH * dpi / 96.0);
                int desiredH = (int)Math.Round(STRIP_HEIGHT * dpi / 96.0);
                int h = Math.Min(desiredH, screen.Height);
                int x = origin.X + client.Right - w;
                // 贴 DSH 客户区右缘，并强制落在主屏内
                if (x + w > screen.Right) x = screen.Right - w;
                if (x < screen.Left) x = screen.Left;
                int y = origin.Y + Math.Max(0, (client.Bottom - h) / 2);
                if (y + h > screen.Bottom) y = screen.Bottom - h;
                if (y < screen.Top) y = screen.Top;
                if (h <= 0) { HideOverlay(); return; }
                Rectangle bounds = new Rectangle(x, y, w, h);
                if (overlay.Bounds != bounds) overlay.Bounds = bounds;
                if (!isVisible)
                {
                    overlay.Show();
                    isVisible = true;
                    Log("overlay shown bounds=" + bounds);
                }
                overlay.TopMost = true;
            }
            else
            {
                HideOverlay();
            }
        }
        catch (Exception ex)
        {
            Log("ERR " + ex.GetType().Name + ": " + ex.Message);
            HideOverlay();
        }
    }

    private void HideOverlay()
    {
        if (!isVisible) return;
        overlay.Hide();
        isVisible = false;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            try { timer.Stop(); timer.Dispose(); } catch { }
            try { overlay.Dispose(); } catch { }
        }
        base.Dispose(disposing);
    }
}

internal static class DshStripGuard
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [STAThread]
    private static void Main(string[] args)
    {
        // Per-Monitor V2，避免 WinForms 把 2560×1440 当成 3840×2160 的虚拟坐标
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
        try { SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        int idle = 60;
        bool force = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--idle" && i + 1 < args.Length)
            {
                int v;
                if (int.TryParse(args[i + 1], out v)) idle = v;
            }
            else if (args[i] == "--force")
            {
                force = true;
            }
        }

        Application.Run(new DshStripGuardContext(idle, force));
    }
}

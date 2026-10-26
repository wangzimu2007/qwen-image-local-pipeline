// WindowGuard —— 让所有普通应用窗口默认留在主屏幕
//
// 规则：
//   1. 新出现的普通窗口，如果落在非主屏（尤其是 800x600 回音壁屏）→ 移到主屏居中
//   2. 从最大化/最小化还原后仍落在非主屏 → 移到主屏
//   3. 已经在主屏的窗口不动（保留应用自己的位置记忆）
//   4. 跳过系统 shell、工具窗口、对话框、无标题窗口、黑屏覆盖层
//
// 编译：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize+ /out:WindowGuard.exe WindowGuard.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

internal static class WindowGuard
{
    private const int SWP_NOZORDER = 0x0004;
    private const int SWP_NOACTIVATE = 0x0010;
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int MONITOR_DEFAULTTOPRIMARY = 0x00000001;
    private const int MONITOR_DEFAULTTONEAREST = 0x00000002;
    private const int GW_OWNER = 4;
    private const int MIN_WIDTH = 240;
    private const int MIN_HEIGHT = 160;
    private const int POLL_MS = 600;

    private const int SW_RESTORE = 9;
    private const int SW_MAXIMIZE = 3;

    private static readonly string LogPath = @"D:\tools\win-layout\window-guard.log";
    private static readonly string LogDir = @"D:\tools\win-layout";
    private static readonly string IgnorePath = @"D:\tools\win-layout\window-guard.ignore";

    private static readonly HashSet<string> ExcludedProcesses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "dwm", "SearchHost", "StartMenuExperienceHost", "ShellExperienceHost",
        "TextInputHost", "LockApp", "LogonUI",
        "BlackDisplay", "WindowGuard", "CenterBrowser", "ScreenshotHotkey"
    };

    private static readonly HashSet<string> ExcludedClasses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW", "DV2ControlHost",
        "Windows.UI.Core.CoreWindow", "SysShadow"
    };

    private static readonly HashSet<string> Ignored = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct WINDOWPLACEMENT
    {
        public int length, flags, showCmd;
        public POINT ptMinPosition, ptMaxPosition;
        public RECT rcNormalPosition;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor, rcWork;
        public int dwFlags;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] private static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFO mi);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);

    private static void Log(string msg)
    {
        try
        {
            var line = string.Format("[{0}] {1}", DateTime.Now.ToString("HH:mm:ss"), msg);
            File.AppendAllText(LogPath, line + Environment.NewLine, Encoding.UTF8);
            var fi = new FileInfo(LogPath);
            if (fi.Length > 512 * 1024)
            {
                var keep = File.ReadAllLines(LogPath);
                var tail = new string[Math.Min(keep.Length, 2000)];
                Array.Copy(keep, keep.Length - tail.Length, tail, 0, tail.Length);
                File.WriteAllLines(LogPath, tail, Encoding.UTF8);
            }
        }
        catch { }
    }

    private static void LoadIgnore()
    {
        try
        {
            if (!File.Exists(IgnorePath)) return;
            foreach (var raw in File.ReadAllLines(IgnorePath))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                Ignored.Add(line);
            }
        }
        catch { }
    }

    private static bool IsIgnoredProcess(string name)
    {
        return ExcludedProcesses.Contains(name) || Ignored.Contains(name);
    }

    private static bool GetPrimaryWorkArea(out RECT work)
    {
        work = new RECT();
        IntPtr mon = MonitorFromWindow(IntPtr.Zero, MONITOR_DEFAULTTOPRIMARY);
        if (mon == IntPtr.Zero) return false;
        var mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(mon, ref mi)) return false;
        work = mi.rcWork;
        return true;
    }

    private static bool IsOnPrimary(IntPtr hWnd)
    {
        IntPtr mon = MonitorFromWindow(hWnd, MONITOR_DEFAULTTONEAREST);
        return mon == MonitorFromWindow(IntPtr.Zero, MONITOR_DEFAULTTOPRIMARY);
    }

    private static void MoveToPrimary(IntPtr hWnd, int w, int h, string why, RECT work)
    {
        int workW = work.Right - work.Left;
        int workH = work.Bottom - work.Top;
        int tw = Math.Min(w, (int)(workW * 0.92));
        int th = Math.Min(h, (int)(workH * 0.92));
        int x = work.Left + (workW - tw) / 2;
        int y = work.Top + (workH - th) / 2;
        bool ok = SetWindowPos(hWnd, IntPtr.Zero, x, y, tw, th, SWP_NOZORDER | SWP_NOACTIVATE);
        if (ok) Log(string.Format("移到主屏({0}) hwnd={1} {2}x{3} -> ({4},{5})", why, hWnd, tw, th, x, y));
    }

    private static void HandleWindow(IntPtr hWnd, Dictionary<IntPtr, int> state, RECT work)
    {
        if (!IsWindowVisible(hWnd)) return;
        if (GetWindowTextLength(hWnd) == 0) return;

        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        string procName;
        try { procName = Process.GetProcessById((int)pid).ProcessName; }
        catch { return; }
        if (IsIgnoredProcess(procName)) return;

        int ex = GetWindowLong(hWnd, GWL_EXSTYLE);
        if ((ex & WS_EX_TOOLWINDOW) != 0) return;
        if ((ex & WS_EX_NOACTIVATE) != 0) return;

        var cls = new StringBuilder(256);
        GetClassName(hWnd, cls, cls.Capacity);
        if (ExcludedClasses.Contains(cls.ToString())) return;

        // 只处理顶层窗口，避免把对话框单独搬走
        if (GetWindow(hWnd, GW_OWNER) != IntPtr.Zero) return;

        RECT r;
        if (!GetWindowRect(hWnd, out r)) return;
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        if (w < MIN_WIDTH || h < MIN_HEIGHT) return;
        if (IsIconic(hWnd)) return;

        var wp = new WINDOWPLACEMENT();
        wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        GetWindowPlacement(hWnd, ref wp);
        int show = wp.showCmd;

        int prev;
        bool known = state.TryGetValue(hWnd, out prev);
        state[hWnd] = show;

        bool offPrimary = !IsOnPrimary(hWnd);
        if (!offPrimary) return;

        if (!known && (show == 1 || show == 3))
        {
            if (show == 3)
            {
                ShowWindow(hWnd, SW_RESTORE);
                MoveToPrimary(hWnd, w, h, "新窗口(最大化)", work);
                ShowWindow(hWnd, SW_MAXIMIZE);
            }
            else
            {
                MoveToPrimary(hWnd, w, h, "新窗口", work);
            }
        }
        else if (known && (prev == 3 || prev == 2 || prev == 6 || prev == 7) && show == 1)
        {
            MoveToPrimary(hWnd, w, h, "还原", work);
        }
    }

    private static void Main()
    {
        try { if (!Directory.Exists(LogDir)) Directory.CreateDirectory(LogDir); } catch { }
        LoadIgnore();
        Log("WindowGuard 启动：轮询 " + POLL_MS + "ms，忽略项 " + Ignored.Count);
        Log("规则：只移动落在非主屏的新窗口/还原窗口；主屏窗口不动");

        var state = new Dictionary<IntPtr, int>();
        var lastCleanup = DateTime.Now;

        while (true)
        {
            RECT work;
            if (GetPrimaryWorkArea(out work))
            {
                EnumWindows((hWnd, lParam) =>
                {
                    try { HandleWindow(hWnd, state, work); }
                    catch { }
                    return true;
                }, IntPtr.Zero);
            }

            if ((DateTime.Now - lastCleanup).TotalMinutes >= 5)
            {
                var alive = new Dictionary<IntPtr, int>();
                foreach (var kv in state)
                {
                    if (IsWindowVisible(kv.Key)) alive[kv.Key] = kv.Value;
                }
                state = alive;
                lastCleanup = DateTime.Now;
            }

            System.Threading.Thread.Sleep(POLL_MS);
        }
    }
}

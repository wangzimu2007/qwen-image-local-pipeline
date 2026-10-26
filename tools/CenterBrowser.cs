// CenterBrowser —— 浏览器小窗口自动居中（C# 编译版，内存约 10MB，无 PowerShell 依赖）
//
// 规则：
//   1. 新出现的浏览器窗口，若不是最大化/最小化 → 居中到最大的显示器
//   2. 窗口从最大化被还原（点"向下还原"）→ 重新居中到最大的显示器
//   3. 已经居中的窗口，你手动拖走不会被反复拽回来
//   4. "最大的显示器"= 工作区面积最大的那块，自动跳过音箱/副屏这类小尺寸虚拟屏
//
// 编译：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize+ /out:CenterBrowser.exe CenterBrowser.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

internal static class CenterBrowser
{
    private const int SWP_NOZORDER = 0x0004;
    private const int SWP_NOACTIVATE = 0x0010;
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int MONITOR_DEFAULTTOPRIMARY = 0x00000001;
    private const int MIN_WIDTH = 320;
    private const int MIN_HEIGHT = 200;
    private const int MIN_USABLE_MONITOR_WIDTH = 1024;   // 小于这个宽度视为“音箱屏”，不作为居中目标
    private const int POLL_MS = 600;
    private static readonly string[] ProcessNames = { "msedge", "chrome", "firefox" };
    private static readonly string LogPath = @"D:\tools\win-layout\center.log";
    private static readonly string LogDir = @"D:\tools\win-layout";

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
    private delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] private static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFO mi);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int index);

    private static void Log(string msg)
    {
        try
        {
            var line = string.Format("[{0}] {1}", DateTime.Now.ToString("HH:mm:ss"), msg);
            File.AppendAllText(LogPath, line + Environment.NewLine, Encoding.UTF8);
            var fi = new FileInfo(LogPath);
            if (fi.Length > 512 * 1024)   // 日志超过 512KB 就截断重写，避免无限增长
            {
                var keep = File.ReadAllLines(LogPath);
                var tail = new string[Math.Min(keep.Length, 2000)];
                Array.Copy(keep, keep.Length - tail.Length, tail, 0, tail.Length);
                File.WriteAllLines(LogPath, tail, Encoding.UTF8);
            }
        }
        catch { }
    }

    // 取“可用的最大显示器”的工作区
    private static bool GetTargetWorkArea(out RECT work)
    {
        RECT best = new RECT();
        bool has = false;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data) =>
        {
            var mi = new MONITORINFO();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfo(hMon, ref mi)) return true;
            int w = mi.rcWork.Right - mi.rcWork.Left;
            int h = mi.rcWork.Bottom - mi.rcWork.Top;
            if (w < MIN_USABLE_MONITOR_WIDTH) return true;          // 跳过音箱屏
            int area = w * h;
            int bestArea = (best.Right - best.Left) * (best.Bottom - best.Top);
            if (!has || area > bestArea) { best = mi.rcWork; has = true; }
            return true;
        }, IntPtr.Zero);
        work = best;
        return has;
    }

    private static void Center(IntPtr hWnd, int w, int h, string why, RECT work)
    {
        int workW = work.Right - work.Left;
        int workH = work.Bottom - work.Top;
        int tw = Math.Min(w, (int)(workW * 0.9));
        int th = Math.Min(h, (int)(workH * 0.9));
        int x = work.Left + (workW - tw) / 2;
        int y = work.Top + (workH - th) / 2;
        bool ok = SetWindowPos(hWnd, IntPtr.Zero, x, y, tw, th, SWP_NOZORDER | SWP_NOACTIVATE);
        if (ok) Log(string.Format("居中({0}) hwnd={1} {2}x{3} -> ({4},{5})", why, hWnd, tw, th, x, y));
    }

    private static void Main()
    {
        try { if (!Directory.Exists(LogDir)) Directory.CreateDirectory(LogDir); } catch { }
        Log("C# 守望启动：进程=" + string.Join(",", ProcessNames) + " 轮询 " + POLL_MS + "ms");

        var state = new Dictionary<IntPtr, int>();
        var lastCleanup = DateTime.Now;

        while (true)
        {
            var targets = new HashSet<uint>();
            foreach (var name in ProcessNames)
            {
                try
                {
                    foreach (var p in Process.GetProcessesByName(name)) targets.Add((uint)p.Id);
                }
                catch { }
            }

            if (targets.Count > 0)
            {
                RECT work;
                bool hasWork = GetTargetWorkArea(out work);
                if (hasWork)
                {
                    EnumWindows((hWnd, lParam) =>
                    {
                        try
                        {
                            if (!IsWindowVisible(hWnd)) return true;

                            uint pid;
                            GetWindowThreadProcessId(hWnd, out pid);
                            if (!targets.Contains(pid)) return true;

                            int ex = GetWindowLong(hWnd, GWL_EXSTYLE);
                            if ((ex & WS_EX_TOOLWINDOW) != 0) return true;

                            RECT r;
                            if (!GetWindowRect(hWnd, out r)) return true;
                            int w = r.Right - r.Left;
                            int h = r.Bottom - r.Top;

                            var wp = new WINDOWPLACEMENT();
                            wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
                            GetWindowPlacement(hWnd, ref wp);
                            int show = wp.showCmd;

                            int prev;
                            bool known = state.TryGetValue(hWnd, out prev);
                            state[hWnd] = show;

                            if (w < MIN_WIDTH || h < MIN_HEIGHT) return true;
                            if (IsIconic(hWnd)) return true;
                            if (show == 2 || show == 6 || show == 7) return true;   // 最小化
                            if (show == 3) return true;                             // 最大化

                            if (!known && show == 1)
                            {
                                Center(hWnd, w, h, "新窗口", work);
                            }
                            else if (known && prev == 3 && show == 1)
                            {
                                Center(hWnd, w, h, "还原", work);
                            }
                        }
                        catch { }
                        return true;
                    }, IntPtr.Zero);
                }
            }

            // 每 5 分钟清理已关闭窗口
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

// BlackHotkey —— 常驻热键启动器
// 热键：Ctrl+Alt+Shift+B 启动 BlackOverlay.exe
// 隐藏窗口，不占任务栏；单实例；日志 blackhotkey.log
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

internal sealed class HiddenForm : Form
{
    public const int WM_HOTKEY = 0x0312;

    protected override void SetVisibleCore(bool value)
    {
        // 永不显示这个窗体，只保留消息循环接收热键
        base.SetVisibleCore(false);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == BlackHotkey.HOTKEY_ID)
        {
            BlackHotkey.LaunchOverlay();
            return;
        }
        base.WndProc(ref m);
    }
}

internal static class BlackHotkey
{
    public const int HOTKEY_ID = 0xB10E;
    private const uint MOD_ALT = 0x0001;
    private const uint MOD_CONTROL = 0x0002;
    private const uint MOD_SHIFT = 0x0004;
    private const uint VK_B = 0x42;

    private static readonly string Dir = @"D:\tools\win-layout";
    private static readonly string Exe = Path.Combine(Dir, "BlackOverlay.exe");
    private static readonly string LogPath = Path.Combine(Dir, "blackhotkey.log");

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private static void Log(string text)
    {
        try
        {
            File.AppendAllText(LogPath,
                "[" + DateTime.Now.ToString("MM-dd HH:mm:ss") + "] " + text + Environment.NewLine);
        }
        catch { }
    }

    public static void LaunchOverlay()
    {
        try
        {
            Process[] existing = Process.GetProcessesByName("BlackOverlay");
            if (existing.Length > 0)
            {
                Log("遮罩已存在，忽略");
                return;
            }
            if (!File.Exists(Exe))
            {
                Log("找不到 BlackOverlay.exe");
                return;
            }
            Process.Start(new ProcessStartInfo(Exe)
            {
                WorkingDirectory = Dir,
                UseShellExecute = true
            });
            Log("已启动黑色遮罩");
        }
        catch (Exception ex)
        {
            Log("启动失败：" + ex.Message);
        }
    }

    [STAThread]
    private static void Main()
    {
        bool created;
        using (Mutex mutex = new Mutex(true, @"Local\BlackOverlayHotkey", out created))
        {
            if (!created) return;

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            HiddenForm form = new HiddenForm();
            form.ShowInTaskbar = false;
            form.FormBorderStyle = FormBorderStyle.None;
            form.StartPosition = FormStartPosition.Manual;
            form.Location = new Point(-32000, -32000);
            form.Size = new Size(1, 1);

            // 显式创建句柄后再注册，确保消息循环能收到 WM_HOTKEY
            IntPtr handle = form.Handle;
            bool ok = RegisterHotKey(handle, HOTKEY_ID,
                MOD_CONTROL | MOD_ALT | MOD_SHIFT, VK_B);
            Log(ok ? "启动器就绪，热键 Ctrl+Alt+Shift+B" : "热键注册失败（可能被其他程序占用）");

            form.FormClosed += delegate
            {
                try { UnregisterHotKey(handle, HOTKEY_ID); } catch { }
            };

            Application.Run(form);
        }
    }
}

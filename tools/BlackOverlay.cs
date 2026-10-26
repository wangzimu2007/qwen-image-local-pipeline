// BlackOverlay —— 主屏纯黑遮罩，防 OLED 烧屏
// 退出：Esc，或 Ctrl+Alt+B（全局兜底）
// 编译：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize+ ^
//     /r:System.Windows.Forms.dll /r:System.Drawing.dll ^
//     /out:BlackOverlay.exe BlackOverlay.cs
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal sealed class BlackOverlayForm : Form
{
    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 0xB10C;
    private const int HOTKEY_ESC = 0xB10D;
    private const uint MOD_ALT = 0x0001;
    private const uint MOD_CONTROL = 0x0002;
    private const uint VK_ESCAPE = 0x1B;

    private const uint ES_CONTINUOUS = 0x80000000;
    private const uint ES_SYSTEM_REQUIRED = 0x00000001;
    private const uint ES_DISPLAY_REQUIRED = 0x00000002;

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int VK_ESCAPE_INT = 0x1B;

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    private readonly DateTime started = DateTime.UtcNow;
    private readonly Timer hintTimer;
    private readonly Timer escTimer;
    private LowLevelKeyboardProc hookProc;
    private IntPtr hookId = IntPtr.Zero;

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && wParam == (IntPtr)WM_KEYDOWN)
        {
            int vk = Marshal.ReadInt32(lParam);
            if (vk == VK_ESCAPE_INT)
            {
                try { BeginInvoke(new MethodInvoker(Close)); } catch { }
                return (IntPtr)1;
            }
        }
        return CallNextHookEx(hookId, nCode, wParam, lParam);
    }

    public BlackOverlayForm()
    {
        SetProcessDPIAware();

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = Screen.PrimaryScreen.Bounds;
        BackColor = Color.Black;
        ForeColor = Color.Black;
        TopMost = true;
        ShowInTaskbar = false;
        ControlBox = false;
        MaximizeBox = false;
        MinimizeBox = false;
        KeyPreview = true;
        DoubleBuffered = true;
        Text = "黑色遮罩";

        hintTimer = new Timer();
        hintTimer.Interval = 250;
        hintTimer.Tick += delegate
        {
            if ((DateTime.UtcNow - started).TotalSeconds >= 3.0)
            {
                hintTimer.Stop();
            }
            Invalidate();
        };

        escTimer = new Timer();
        escTimer.Interval = 50;
        escTimer.Tick += delegate
        {
            if ((GetAsyncKeyState(VK_ESCAPE_INT) & 0x8000) != 0)
            {
                escTimer.Stop();
                Close();
            }
        };
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        try { Cursor.Hide(); } catch { }
        // 保持屏幕和系统唤醒，音频继续；关闭时恢复
        try { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED); } catch { }
        Activate();
        SetForegroundWindow(Handle);
        Focus();
        // 低级键盘钩子：不依赖窗口焦点，遮罩存在期间 Esc 直接退出
        hookProc = HookCallback;
        hookId = SetWindowsHookEx(WH_KEYBOARD_LL, hookProc, GetModuleHandle(null), 0);
        escTimer.Start();
        hintTimer.Start();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        // 全局兜底：Ctrl+Alt+B 和 Esc；即使窗口失焦也能退出
        RegisterHotKey(Handle, HOTKEY_ID, MOD_CONTROL | MOD_ALT, 0x42);
        RegisterHotKey(Handle, HOTKEY_ESC, 0, VK_ESCAPE);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && (m.WParam.ToInt32() == HOTKEY_ID || m.WParam.ToInt32() == HOTKEY_ESC))
        {
            Close();
            return;
        }
        base.WndProc(ref m);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape)
        {
            e.Handled = true;
            Close();
            return;
        }
        base.OnKeyDown(e);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        // 鼠标兜底：任何点击都退出，避免焦点异常时被困在黑屏里
        base.OnMouseDown(e);
        Close();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        double elapsed = (DateTime.UtcNow - started).TotalSeconds;
        if (elapsed < 3.0)
        {
            string text = "按 Esc / Ctrl+Alt+B，或点击屏幕退出";
            using (Font font = new Font("Microsoft YaHei UI", 14f, FontStyle.Regular, GraphicsUnit.Point))
            using (SolidBrush brush = new SolidBrush(Color.FromArgb(90, 90, 90)))
            {
                SizeF size = e.Graphics.MeasureString(text, font);
                float x = (ClientSize.Width - size.Width) / 2f;
                float y = ClientSize.Height - size.Height - 40f;
                e.Graphics.DrawString(text, font, brush, x, y);
            }
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        try { hintTimer.Stop(); } catch { }
        try { escTimer.Stop(); } catch { }
        try { if (hookId != IntPtr.Zero) UnhookWindowsHookEx(hookId); } catch { }
        try { UnregisterHotKey(Handle, HOTKEY_ID); } catch { }
        try { UnregisterHotKey(Handle, HOTKEY_ESC); } catch { }
        try { Cursor.Show(); } catch { }
        try { SetThreadExecutionState(ES_CONTINUOUS); } catch { }
        base.OnFormClosed(e);
    }

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new BlackOverlayForm());
    }
}

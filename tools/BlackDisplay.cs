// BlackDisplay —— 在 800x600 回音壁“显示器”上盖一层纯黑窗口
//
// 目的：让那块 HDMI 屏不显示桌面/壁纸/图标，同时保持 HDMI 音频端点存活。
// 注意：Windows 的 Win+PrtScn 全屏截图仍会包含这块黑屏区域；要去掉只能：
//   - 用 Win+Shift+S / 截图工具只截主屏，或
//   - 使用 Enterprise / Pro for Workstations 的“从桌面删除显示器”，或
//   - 接受黑块。
//
// 编译：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize+ ^
//     /r:System.Windows.Forms.dll /r:System.Drawing.dll ^
//     /out:BlackDisplay.exe BlackDisplay.cs
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal sealed class BlackDisplayForm : Form
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

internal static class BlackDisplay
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [STAThread]
    private static void Main()
    {
        try { SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();

        Screen target = null;
        foreach (Screen screen in Screen.AllScreens)
        {
            if (screen.Primary) continue;
            // 物理分辨率 1200x900（显示设置里按 150% 缩放显示为 800x600）
            if (screen.Bounds.Width < 1600 && screen.Bounds.Height < 1200)
            {
                target = screen;
                break;
            }
        }
        if (target == null) return;

        var form = new BlackDisplayForm();
        form.FormBorderStyle = FormBorderStyle.None;
        form.StartPosition = FormStartPosition.Manual;
        form.Bounds = target.Bounds;
        form.BackColor = Color.Black;
        form.ForeColor = Color.Black;
        form.TopMost = true;
        form.ShowInTaskbar = false;
        form.ControlBox = false;
        form.MaximizeBox = false;
        form.MinimizeBox = false;
        form.Cursor = Cursors.Default;
        form.Text = "BlackDisplay";

        Application.Run(form);
    }
}

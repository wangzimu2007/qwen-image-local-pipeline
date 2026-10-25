// StrataTray.cs — 任务栏托盘，显示本地模型后端状态（自动识别 Strata / Ollama / NInfer）
// 状态：就绪(绿) / 出图中(蓝) / 恢复中(橙) / 启动中(黄) / 离线(红)
// 数据来源：调用 D:\qwen-image-2.1\看状态.ps1 -Json（单一事实来源，避免逻辑重复）
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace StrataTray
{
    public class TrayApp : ApplicationContext
    {
        private readonly NotifyIcon _tray;
        private readonly Timer _timer;
        private string _lastState = "";
        private readonly string _statusScript = @"D:\qwen-image-2.1\看状态.ps1";
        private readonly string _startAll = @"D:\qwen-image-2.1\启动守护.ps1";
        private readonly string _strataStop = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Strata\actions\stop-iq3s.cmd");

        private Icon _iGreen, _iBlue, _iOrange, _iYellow, _iRed;
        private bool _busy = false;

        public TrayApp()
        {
            _iGreen = Circle(Color.FromArgb(46, 204, 113));
            _iBlue = Circle(Color.FromArgb(52, 152, 219));
            _iOrange = Circle(Color.FromArgb(243, 156, 18));
            _iYellow = Circle(Color.FromArgb(241, 196, 15));
            _iRed = Circle(Color.FromArgb(231, 76, 60));

            var menu = new ContextMenuStrip();
            menu.Items.Add("查看详情", null, (s, e) => OpenStatus());
            menu.Items.Add("启动本地后端 / 守护（一键）", null, (s, e) => RunPs(_startAll));
            menu.Items.Add("停止 Strata", null, (s, e) => RunCmd(_strataStop));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("立即刷新", null, (s, e) => Tick());
            menu.Items.Add("退出", null, (s, e) => ExitApp());

            _tray = new NotifyIcon();
            _tray.Icon = _iRed;
            _tray.Text = "本地模型: 检测中…";
            _tray.Visible = true;
            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += (s, e) => OpenStatus();

            _timer = new Timer();
            _timer.Interval = 4000;
            _timer.Tick += (s, e) => Tick();
            _timer.Start();

            Tick();
        }

        private static Icon Circle(Color c)
        {
            var bmp = new Bitmap(32, 32);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (var pen = new Pen(Color.FromArgb(220, 20, 20, 20), 2.5f))
                using (var brush = new SolidBrush(c))
                {
                    g.FillEllipse(brush, 4, 4, 24, 24);
                    g.DrawEllipse(pen, 4, 4, 24, 24);
                }
            }
            return Icon.FromHandle(bmp.GetHicon());
        }

        // 调用 看状态.ps1 -Json，返回 (state, detail, kind)
        private string QueryState(out string detail, out string kind)
        {
            detail = ""; kind = "";
            try
            {
                var psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -File \"" + _statusScript + "\" -Json")
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using (var p = Process.Start(psi))
                {
                    string json = p.StandardOutput.ReadToEnd();
                    p.WaitForExit(20000);
                    var ms = Regex.Match(json, "\"state\"\\s*:\\s*\"([^\"]*)\"");
                    var md = Regex.Match(json, "\"detail\"\\s*:\\s*\"([^\"]*)\"");
                    var mk = Regex.Match(json, "\"activeKind\"\\s*:\\s*\"([^\"]*)\"");
                    if (ms.Success) { detail = md.Success ? md.Groups[1].Value : ""; kind = mk.Success ? mk.Groups[1].Value : ""; return ms.Groups[1].Value; }
                }
            }
            catch { }
            return "";
        }

        private void Tick()
        {
            if (_busy) return;
            _busy = true;
            try
            {
                string detail, kind;
                string state = QueryState(out detail, out kind);
                if (string.IsNullOrEmpty(state)) { SetState("离线", "状态脚本无响应", _iRed); return; }

                Icon icon;
                switch (state)
                {
                    case "就绪": icon = _iGreen; break;
                    case "出图中": icon = _iBlue; break;
                    case "恢复中": icon = _iOrange; break;
                    case "启动中": icon = _iYellow; break;
                    default: state = "离线"; icon = _iRed; break;
                }
                SetState(state, detail, icon);
            }
            finally { _busy = false; }
        }

        private void SetState(string state, string detail, Icon icon)
        {
            string text = "本地模型: " + state + (detail == "" ? "" : " — " + detail);
            if (text.Length > 63) text = text.Substring(0, 63);
            _tray.Text = text;

            if (state != _lastState)
            {
                _tray.Icon = icon;
                _tray.Visible = true;
                if (_lastState != "")
                {
                    try { _tray.ShowBalloonTip(1500, "本地模型 " + state, detail, ToolTipIcon.None); } catch { }
                }
                Log("状态 " + state + "（" + detail + "）");
                _lastState = state;
            }
        }

        private static void Log(string msg)
        {
            try
            {
                var p = @"D:\qwen-image-2.1\.strata-tray.log";
                if (File.Exists(p) && new FileInfo(p).Length > 256 * 1024) File.Delete(p);
                File.AppendAllText(p, "[" + DateTime.Now.ToString("MM-dd HH:mm:ss") + "] " + msg + Environment.NewLine);
            }
            catch { }
        }

        private static void RunCmd(string path)
        {
            try
            {
                if (!File.Exists(path)) { MessageBox.Show("找不到：" + path); return; }
                var psi = new ProcessStartInfo("cmd.exe", "/c \"" + path + "\"") { WindowStyle = ProcessWindowStyle.Hidden, CreateNoWindow = true };
                Process.Start(psi);
                Log("执行：" + Path.GetFileName(path));
            }
            catch (Exception ex) { Log("执行失败：" + ex.Message); }
        }

        private static void RunPs(string script)
        {
            try
            {
                var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"")
                { WindowStyle = ProcessWindowStyle.Hidden, CreateNoWindow = true };
                Process.Start(psi);
                Log("执行：" + Path.GetFileName(script));
            }
            catch (Exception ex) { Log("执行失败：" + ex.Message); }
        }

        private void OpenStatus()
        {
            try
            {
                var psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -NoExit -File \"" + _statusScript + "\"")
                { WorkingDirectory = @"D:\qwen-image-2.1" };
                Process.Start(psi);
            }
            catch (Exception ex) { Log("打开状态窗口失败：" + ex.Message); }
        }

        private void ExitApp()
        {
            _timer.Stop();
            _tray.Visible = false;
            _tray.Dispose();
            Log("托盘退出");
            ExitThread();
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool created;
            using (var mutex = new System.Threading.Mutex(true, "StrataTray_SingleInstance", out created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
            }
        }
    }
}

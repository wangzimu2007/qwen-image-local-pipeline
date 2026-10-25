// StrataTray.cs — 任务栏托盘小图标，实时显示 Strata 状态
// 状态：就绪(绿) / 出图中(蓝) / 恢复中(橙) / 启动中(黄) / 离线(红)
// 编译：csc /target:winexe /out:StrataTray.exe StrataTray.cs /r:System.Windows.Forms.dll /r:System.Drawing.dll
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Windows.Forms;

namespace StrataTray
{
    public class TrayApp : ApplicationContext
    {
        private readonly NotifyIcon _tray;
        private readonly Timer _timer;
        private string _lastState = "";
        private readonly string _jobsRoot = @"D:\qwen-image-2.1\.jobs";
        private readonly string _statusScript = @"D:\qwen-image-2.1\看状态.ps1";
        private readonly string _strataStart = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Strata\actions\start-iq3s.cmd");
        private readonly string _strataStop = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Strata\actions\stop-iq3s.cmd");

        private Icon _iconGreen, _iconBlue, _iconOrange, _iconYellow, _iconRed;

        public TrayApp()
        {
            _iconGreen = MakeCircleIcon(Color.FromArgb(46, 204, 113));
            _iconBlue = MakeCircleIcon(Color.FromArgb(52, 152, 219));
            _iconOrange = MakeCircleIcon(Color.FromArgb(243, 156, 18));
            _iconYellow = MakeCircleIcon(Color.FromArgb(241, 196, 15));
            _iconRed = MakeCircleIcon(Color.FromArgb(231, 76, 60));

            var menu = new ContextMenuStrip();
            menu.Items.Add("查看详情（打开状态窗口）", null, (s, e) => ShowStatusWindow());
            menu.Items.Add("启动 Strata", null, (s, e) => RunCmd(_strataStart));
            menu.Items.Add("停止 Strata", null, (s, e) => RunCmd(_strataStop));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("立即刷新", null, (s, e) => Tick());
            menu.Items.Add("退出", null, (s, e) => ExitApp());

            _tray = new NotifyIcon();
            _tray.Icon = _iconRed;
            _tray.Text = "Strata: 检测中…";
            _tray.Visible = true;
            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += (s, e) => ShowStatusWindow();

            _timer = new Timer();
            _timer.Interval = 3000;
            _timer.Tick += (s, e) => Tick();
            _timer.Start();

            Tick();
        }

        private static Icon MakeCircleIcon(Color color)
        {
            var bmp = new Bitmap(32, 32);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                // 外圈深色描边，内圈实心圆
                using (var pen = new Pen(Color.FromArgb(220, 20, 20, 20), 2.5f))
                using (var brush = new SolidBrush(color))
                {
                    g.FillEllipse(brush, 4, 4, 24, 24);
                    g.DrawEllipse(pen, 4, 4, 24, 24);
                }
            }
            return Icon.FromHandle(bmp.GetHicon());
        }

        private static bool PortOpen(int port)
        {
            try
            {
                using (var c = new TcpClient())
                {
                    var ar = c.BeginConnect("127.0.0.1", port, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(250)) return false;
                    c.EndConnect(ar);
                    return true;
                }
            }
            catch { return false; }
        }

        private static bool Serving()
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:8080/v1/models");
                req.Timeout = 1200;
                using (var resp = (HttpWebResponse)req.GetResponse())
                    return resp.StatusCode == HttpStatusCode.OK;
            }
            catch { return false; }
        }

        private int CountJson(string sub)
        {
            try
            {
                var d = Path.Combine(_jobsRoot, sub);
                if (!Directory.Exists(d)) return 0;
                return Directory.GetFiles(d, "*.json").Length;
            }
            catch { return 0; }
        }

        private void Tick()
        {
            try
            {
                int pending = CountJson("pending");
                int running = CountJson("running");
                bool hasLock = File.Exists(Path.Combine(_jobsRoot, "guardian.lock"));
                bool p8080 = PortOpen(8080);
                bool p8081 = PortOpen(8081);
                int strataProcs = 0;
                try { strataProcs = System.Diagnostics.Process.GetProcessesByName("strata").Length; } catch { }

                string state;
                Icon icon;
                string detail;

                if (running > 0 || pending > 0)
                {
                    state = "出图中";
                    icon = _iconBlue;
                    detail = running > 0 ? ("任务执行中，排队 " + pending) : (pending + " 个作业排队");
                }
                else if (hasLock)
                {
                    state = "恢复中";
                    icon = _iconOrange;
                    detail = "守护在恢复后端（约 45~70 秒）";
                }
                else if (p8080 && Serving())
                {
                    state = "就绪";
                    icon = _iconGreen;
                    detail = "本地模型可用";
                }
                else if (strataProcs > 0 || p8080)
                {
                    state = "启动中";
                    icon = _iconYellow;
                    detail = "Strata 正在加载模型（40~90 秒）";
                }
                else
                {
                    state = "离线";
                    icon = _iconRed;
                    detail = "双击「Strata IQ3_S - 启动」拉起";
                }

                string text = "Strata: " + state + " — " + detail;
                if (text.Length > 63) text = text.Substring(0, 63);
                _tray.Text = text;

                if (state != _lastState)
                {
                    _tray.Icon = icon;
                    _tray.Visible = true;
                    if (_lastState != "")
                    {
                        try { _tray.ShowBalloonTip(1500, "Strata " + state, detail, ToolTipIcon.None); } catch { }
                    }
                    Log("状态 " + state + "（队列 " + running + "+" + pending + "，锁=" + hasLock + "，8080=" + p8080 + "，8081=" + p8081 + "）");
                    _lastState = state;
                }
            }
            catch (Exception ex) { Log("检查失败: " + ex.Message); }
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

        private void RunCmd(string path)
        {
            try
            {
                if (!File.Exists(path)) { MessageBox.Show("找不到：" + path); return; }
                var psi = new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c \"" + path + "\"");
                psi.WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden;
                psi.CreateNoWindow = true;
                System.Diagnostics.Process.Start(psi);
                Log("执行：" + Path.GetFileName(path));
            }
            catch (Exception ex) { Log("执行失败：" + ex.Message); }
        }

        private void ShowStatusWindow()
        {
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -NoExit -File \"" + _statusScript + "\"");
                psi.WorkingDirectory = @"D:\qwen-image-2.1";
                System.Diagnostics.Process.Start(psi);
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
            // 单实例
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

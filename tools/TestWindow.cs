using System;
using System.Drawing;
using System.Windows.Forms;
internal static class TestWindow {
    [STAThread]
    private static void Main() {
        Application.EnableVisualStyles();
        var f = new Form();
        f.Text = "WindowGuardTest";
        f.StartPosition = FormStartPosition.Manual;
        f.Location = new Point(-700, -500);
        f.Size = new Size(600, 400);
        f.Show();
        Application.Run(f);
    }
}
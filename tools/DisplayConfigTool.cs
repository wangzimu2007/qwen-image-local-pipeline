using System;
using System.Runtime.InteropServices;

public static class DisplayConfigTool
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct REGION2D { public uint cx; public uint cy; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECTL { public int left; public int top; public int right; public int bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct VIDEO_SIGNAL_INFO
    {
        public ulong pixelRate;
        public RATIONAL hSyncFreq;
        public RATIONAL vSyncFreq;
        public REGION2D activeSize;
        public REGION2D totalSize;
        public uint videoStandard;
        public uint scanLineOrdering;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TARGET_MODE { public VIDEO_SIGNAL_INFO targetVideoSignalInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SOURCE_MODE
    {
        public uint width;
        public uint height;
        public uint pixelFormat;
        public POINTL position;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DESKTOP_IMAGE_INFO
    {
        public POINTL PathSourceSize;
        public RECTL DesktopImageRegion;
        public RECTL DesktopImageClip;
    }

    [StructLayout(LayoutKind.Explicit, Size = 64)]
    public struct MODE_INFO
    {
        [FieldOffset(0)] public uint infoType;
        [FieldOffset(4)] public uint id;
        [FieldOffset(8)] public LUID adapterId;
        [FieldOffset(16)] public TARGET_MODE targetMode;
        [FieldOffset(16)] public SOURCE_MODE sourceMode;
        [FieldOffset(16)] public DESKTOP_IMAGE_INFO desktopImageInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_SOURCE_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_TARGET_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public uint refreshRateNumerator;
        public uint refreshRateDenominator;
        public uint scanLineOrdering;
        public uint targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_INFO
    {
        public PATH_SOURCE_INFO sourceInfo;
        public PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);
    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint numPath, [Out] PATH_INFO[] paths,
        ref uint numMode, [Out] MODE_INFO[] modes, IntPtr currentTopologyId);
    [DllImport("user32.dll")]
    private static extern int SetDisplayConfig(uint numPath, PATH_INFO[] paths, uint numMode,
        MODE_INFO[] modes, uint flags);

    private const uint QDC_ALL_PATHS = 1;
    private const uint SDC_APPLY = 0x80;
    private const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x10;
    private const uint SDC_SAVE_TO_DATABASE = 0x8;
    private const uint SDC_ALLOW_CHANGES = 0x400;
    private const uint FLAGS = SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES;
    private const uint PATH_ACTIVE = 1;
    private const uint MODE_INFO_SOURCE = 1;
    private const uint INVALID_IDX = 0xFFFFFFFF;

    private static PATH_INFO[] savedPaths;
    private static MODE_INFO[] savedModes;

    private static int Query(out PATH_INFO[] paths, out MODE_INFO[] modes)
    {
        paths = null;
        modes = null;
        uint numPath;
        uint numMode;
        int rc = GetDisplayConfigBufferSizes(QDC_ALL_PATHS, out numPath, out numMode);
        if (rc != 0) return rc;
        paths = new PATH_INFO[numPath];
        modes = new MODE_INFO[numMode];
        rc = QueryDisplayConfig(QDC_ALL_PATHS, ref numPath, paths, ref numMode, modes, IntPtr.Zero);
        if (rc != 0) return rc;
        Array.Resize(ref paths, (int)numPath);
        Array.Resize(ref modes, (int)numMode);
        return 0;
    }

    private static string ModeText(PATH_INFO p, MODE_INFO[] modes)
    {
        uint idx = p.sourceInfo.modeInfoIdx;
        if (idx == INVALID_IDX || idx >= modes.Length) return "?";
        MODE_INFO m = modes[idx];
        if (m.infoType != MODE_INFO_SOURCE) return "?";
        return m.sourceMode.width + "x" + m.sourceMode.height + " @ " + m.sourceMode.position.x + "," + m.sourceMode.position.y;
    }

    public static int List()
    {
        PATH_INFO[] paths;
        MODE_INFO[] modes;
        int rc = Query(out paths, out modes);
        if (rc != 0) { Console.WriteLine("query rc=" + rc); return rc; }
        for (int i = 0; i < paths.Length; i++)
        {
            PATH_INFO p = paths[i];
            Console.WriteLine(i + ": active=" + ((p.flags & PATH_ACTIVE) != 0) + " source=" + p.sourceInfo.id +
                " target=" + p.targetInfo.id + " mode=" + ModeText(p, modes) +
                " available=" + p.targetInfo.targetAvailable);
        }
        return 0;
    }

    public static int Disable800()
    {
        PATH_INFO[] paths;
        MODE_INFO[] modes;
        int rc = Query(out paths, out modes);
        if (rc != 0) { Console.WriteLine("query rc=" + rc); return rc; }
        savedPaths = (PATH_INFO[])paths.Clone();
        savedModes = (MODE_INFO[])modes.Clone();

        var keep = new System.Collections.Generic.List<PATH_INFO>();
        bool found = false;
        for (int i = 0; i < paths.Length; i++)
        {
            PATH_INFO p = paths[i];
            if ((p.flags & PATH_ACTIVE) == 0) continue;
            uint idx = p.sourceInfo.modeInfoIdx;
            bool phantom = false;
            if (idx != INVALID_IDX && idx < modes.Length && modes[idx].infoType == MODE_INFO_SOURCE)
            {
                SOURCE_MODE sm = modes[idx].sourceMode;
                phantom = sm.width == 800 && sm.height == 600;
            }
            if (phantom) { found = true; continue; }
            keep.Add(p);
        }
        if (!found) { Console.WriteLine("800x600 path not found"); return 2; }
        PATH_INFO[] newPaths = keep.ToArray();
        rc = SetDisplayConfig((uint)newPaths.Length, newPaths, (uint)modes.Length, modes, FLAGS);
        Console.WriteLine("set disable rc=" + rc + " kept=" + newPaths.Length + " modes=" + modes.Length);
        return rc;
    }

    public static int Restore()
    {
        if (savedPaths == null || savedModes == null) { Console.WriteLine("no saved config"); return 3; }
        int rc = SetDisplayConfig((uint)savedPaths.Length, savedPaths, (uint)savedModes.Length, savedModes, FLAGS);
        Console.WriteLine("restore rc=" + rc + " paths=" + savedPaths.Length + " modes=" + savedModes.Length);
        return rc;
    }

    public static int Main(string[] args)
    {
        string cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "list";
        if (cmd == "list") return List();
        if (cmd == "disable800") return Disable800();
        if (cmd == "restore") return Restore();
        Console.WriteLine("usage: list | disable800 | restore");
        return 1;
    }
}

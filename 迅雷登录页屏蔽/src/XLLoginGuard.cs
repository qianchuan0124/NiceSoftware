// XLLoginGuard - silently closes Thunder's auto login window (Xunlei / Thunder Network).
//
// What it does
//   Thunder (11.x, Electron UI) pops a window titled "XunLei personal center - login"
//   (600x440, class Chrome_WidgetWin_0) once per day when it starts. This tiny tray-less
//   guard enumerates top-level windows a few times per second and closes that window as
//   soon as it appears, together with its XL_ShadowWindow companion.
//
// Safety rails
//   * Only windows owned by a process named "Thunder" (configurable) are touched.
//   * Only windows whose title contains the login keyword are touched.
//   * A window that shows up within StartupGraceSeconds after Thunder.exe started is
//     treated as an automatic popup and closed even if the user is typing.
//   * After that grace period the window is only closed while the desktop has been idle
//     for IdleThresholdMs or more, i.e. the user did not just click something. A login
//     window opened on purpose by the user is therefore left alone.
//
// Configuration (optional, next to the exe):
//   guard.ini  with key=value lines, keys:
//     ProcessName=Thunder
//     TitleKeyword=<login keyword, default U+767B U+5F55>
//     ClassPrefix=Chrome_WidgetWin
//     MinWidth=200
//     MinHeight=150
//     StartupGraceSeconds=25
//     IdleThresholdMs=1500
//     PollIntervalMs=400
//
// The source is intentionally ASCII-only (Chinese default comes from escape sequences),
// so it compiles correctly no matter which code page csc.exe assumes.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace XLLoginGuard
{
    internal static class Program
    {
        private const int WM_CLOSE = 0x0010;
        private const int SW_HIDE = 0;
        private const int MaxLogBytes = 512 * 1024;

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO
        {
            public uint cbSize;
            public uint dwTime;
        }

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder buffer, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder buffer, int maxCount);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr hWnd, int message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        private sealed class Options
        {
            public string ProcessName = "Thunder";
            public string TitleKeyword = "\u767B\u5F55"; // "login" in Chinese
            public string ClassPrefix = "Chrome_WidgetWin";
            public int MinWidth = 200;
            public int MinHeight = 150;
            public int StartupGraceSeconds = 25;
            public int IdleThresholdMs = 1500;
            public int PollIntervalMs = 400;
        }

        private sealed class WinInfo
        {
            public IntPtr Handle;
            public uint ProcessId;
            public string ClassName;
            public string Title;
            public RECT Rect;
        }

        private static readonly object LogLock = new object();
        private static string _logPath;

        private static int Main()
        {
            bool createdNew;
            using (var mutex = new Mutex(true, @"Local\XLLoginGuard_SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    return 0;
                }

                var exeDir = Path.GetDirectoryName(typeof(Program).Assembly.Location);
                var options = LoadOptions(Path.Combine(exeDir, "guard.ini"));
                _logPath = Path.Combine(exeDir, "guard.log");

                Log(string.Format(CultureInfo.InvariantCulture,
                    "started pid={0} process={1} keyword={2} grace={3}s idle>={4}ms poll={5}ms",
                    Process.GetCurrentProcess().Id, options.ProcessName, options.TitleKeyword,
                    options.StartupGraceSeconds, options.IdleThresholdMs, options.PollIntervalMs));

                foreach (var arg in Environment.GetCommandLineArgs())
                {
                    if (string.Equals(arg, "--once", StringComparison.OrdinalIgnoreCase))
                    {
                        var closed = Scan(options);
                        Log("single scan finished, closed=" + closed);
                        return 0;
                    }
                }

                while (true)
                {
                    try
                    {
                        Scan(options);
                    }
                    catch (Exception ex)
                    {
                        Log("scan error: " + ex.Message);
                    }

                    Thread.Sleep(Math.Max(100, options.PollIntervalMs));
                }
            }
        }

        private static Options LoadOptions(string iniPath)
        {
            var options = new Options();
            try
            {
                if (!File.Exists(iniPath))
                {
                    return options;
                }

                foreach (var raw in File.ReadAllLines(iniPath, Encoding.UTF8))
                {
                    var line = raw.Trim();
                    if (line.Length == 0 || line[0] == '#' || line[0] == ';' || line[0] == '[')
                    {
                        continue;
                    }

                    var eq = line.IndexOf('=');
                    if (eq <= 0)
                    {
                        continue;
                    }

                    var key = line.Substring(0, eq).Trim().ToLowerInvariant();
                    var value = line.Substring(eq + 1).Trim();
                    int number;

                    switch (key)
                    {
                        case "processname":
                            options.ProcessName = value;
                            break;
                        case "titlekeyword":
                            options.TitleKeyword = value;
                            break;
                        case "classprefix":
                            options.ClassPrefix = value;
                            break;
                        case "minwidth":
                            if (int.TryParse(value, out number)) options.MinWidth = number;
                            break;
                        case "minheight":
                            if (int.TryParse(value, out number)) options.MinHeight = number;
                            break;
                        case "startupgraceseconds":
                            if (int.TryParse(value, out number)) options.StartupGraceSeconds = number;
                            break;
                        case "idlethresholdms":
                            if (int.TryParse(value, out number)) options.IdleThresholdMs = number;
                            break;
                        case "pollintervalms":
                            if (int.TryParse(value, out number)) options.PollIntervalMs = number;
                            break;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("guard.ini read error: " + ex.Message);
            }

            return options;
        }

        private static int Scan(Options options)
        {
            var closed = 0;
            var windows = new List<WinInfo>();

            EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd))
                {
                    return true;
                }

                var classBuffer = new StringBuilder(128);
                GetClassName(hWnd, classBuffer, classBuffer.Capacity);
                var className = classBuffer.ToString();
                if (!className.StartsWith(options.ClassPrefix, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }

                var titleBuffer = new StringBuilder(512);
                GetWindowText(hWnd, titleBuffer, titleBuffer.Capacity);
                var title = titleBuffer.ToString();

                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);

                RECT rect;
                GetWindowRect(hWnd, out rect);

                windows.Add(new WinInfo
                {
                    Handle = hWnd,
                    ProcessId = pid,
                    ClassName = className,
                    Title = title,
                    Rect = rect
                });

                return true;
            }, IntPtr.Zero);

            if (windows.Count == 0)
            {
                return 0;
            }

            var processNames = new Dictionary<uint, string>();
            var idleMs = GetIdleMilliseconds();
            var now = DateTime.UtcNow;

            foreach (var window in windows)
            {
                if (window.Title.IndexOf(options.TitleKeyword, StringComparison.OrdinalIgnoreCase) < 0)
                {
                    continue;
                }

                var width = window.Rect.Right - window.Rect.Left;
                var height = window.Rect.Bottom - window.Rect.Top;
                if (width < options.MinWidth || height < options.MinHeight)
                {
                    continue;
                }

                string processName;
                if (!processNames.TryGetValue(window.ProcessId, out processName))
                {
                    processName = GetProcessName(window.ProcessId);
                    processNames[window.ProcessId] = processName;
                }

                if (!string.Equals(processName, options.ProcessName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var uptimeSeconds = GetProcessUptimeSeconds(window.ProcessId, now);
                var insideGrace = uptimeSeconds >= 0 && uptimeSeconds < options.StartupGraceSeconds;
                var idleEnough = idleMs >= options.IdleThresholdMs;

                if (!insideGrace && !idleEnough)
                {
                    Log(string.Format(CultureInfo.InvariantCulture,
                        "skip (looks user-initiated): title=[{0}] pid={1} uptime={2}s idle={3}ms",
                        window.Title, window.ProcessId, uptimeSeconds, idleMs));
                    continue;
                }

                Log(string.Format(CultureInfo.InvariantCulture,
                    "closing login window: title=[{0}] pid={1} size={2}x{3} uptime={4}s idle={5}ms",
                    window.Title, window.ProcessId, width, height, uptimeSeconds, idleMs));

                ShowWindow(window.Handle, SW_HIDE);
                PostMessage(window.Handle, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                closed++;

                CloseShadowWindows(window, options);
            }

            return closed;
        }

        private static void CloseShadowWindows(WinInfo loginWindow, Options options)
        {
            var expanded = new RECT
            {
                Left = loginWindow.Rect.Left - 8,
                Top = loginWindow.Rect.Top - 8,
                Right = loginWindow.Rect.Right + 8,
                Bottom = loginWindow.Rect.Bottom + 8
            };

            try
            {
                EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
                {
                    if (!IsWindowVisible(hWnd) || hWnd == loginWindow.Handle)
                    {
                        return true;
                    }

                    var classBuffer = new StringBuilder(128);
                    GetClassName(hWnd, classBuffer, classBuffer.Capacity);
                    if (!string.Equals(classBuffer.ToString(), "XL_ShadowWindow", StringComparison.Ordinal))
                    {
                        return true;
                    }

                    uint pid;
                    GetWindowThreadProcessId(hWnd, out pid);
                    if (pid != loginWindow.ProcessId)
                    {
                        return true;
                    }

                    RECT rect;
                    GetWindowRect(hWnd, out rect);
                    if (Math.Abs(rect.Left - expanded.Left) <= 12 &&
                        Math.Abs(rect.Top - expanded.Top) <= 12 &&
                        Math.Abs(rect.Right - expanded.Right) <= 12 &&
                        Math.Abs(rect.Bottom - expanded.Bottom) <= 12)
                    {
                        ShowWindow(hWnd, SW_HIDE);
                        Log("closing shadow window pid=" + pid);
                    }

                    return true;
                }, IntPtr.Zero);
            }
            catch (Exception ex)
            {
                Log("shadow scan error: " + ex.Message);
            }
        }

        private static string GetProcessName(uint pid)
        {
            try
            {
                using (var process = Process.GetProcessById((int)pid))
                {
                    return process.ProcessName;
                }
            }
            catch
            {
                return string.Empty;
            }
        }

        private static double GetProcessUptimeSeconds(uint pid, DateTime nowUtc)
        {
            try
            {
                using (var process = Process.GetProcessById((int)pid))
                {
                    return (nowUtc - process.StartTime.ToUniversalTime()).TotalSeconds;
                }
            }
            catch
            {
                return -1;
            }
        }

        private static long GetIdleMilliseconds()
        {
            var info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref info))
            {
                return long.MaxValue;
            }

            var tickCount = (uint)Environment.TickCount;
            return unchecked((long)(tickCount - info.dwTime));
        }

        private static void Log(string message)
        {
            try
            {
                lock (LogLock)
                {
                    if (_logPath == null)
                    {
                        return;
                    }

                    var info = new FileInfo(_logPath);
                    if (info.Exists && info.Length > MaxLogBytes)
                    {
                        var backup = _logPath + ".1";
                        if (File.Exists(backup))
                        {
                            File.Delete(backup);
                        }

                        File.Move(_logPath, backup);
                    }

                    File.AppendAllText(_logPath, string.Format(CultureInfo.InvariantCulture,
                        "{0:yyyy-MM-dd HH:mm:ss.fff}  {1}{2}",
                        DateTime.Now, message, Environment.NewLine), new UTF8Encoding(false));
                }
            }
            catch
            {
                // Logging must never take the guard down.
            }
        }
    }
}

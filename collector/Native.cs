using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class WeChatNative {
    public delegate bool EnumProc(IntPtr handle, IntPtr param);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr param);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder b, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    public static bool IsForeground(long h) { var target=new IntPtr(h); var f=GetForegroundWindow(); return f==target || f==GetAncestor(target,2); }
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern bool OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll",EntryPoint="OpenInputDesktop")] static extern IntPtr InputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern bool SwitchDesktop(IntPtr h);
    public static bool InteractiveDesktop() { var h=InputDesktop(0,false,0x0100); if(h==IntPtr.Zero)return false; try{return SwitchDesktop(h);}finally{CloseDesktop(h);} }
    public static void Click(int x,int y) { SetCursorPos(x,y); mouse_event(2,0,0,0,UIntPtr.Zero); mouse_event(4,0,0,0,UIntPtr.Zero); }
    public static void Wheel(int x,int y) { SetCursorPos(x,y); mouse_event(2048,0,0,unchecked((uint)-1200),UIntPtr.Zero); }
    public static long[] BrowserHandles(long main, uint[] pids) {
        var result=new HashSet<long>();
        EnumProc cb=(h,p)=>{uint id;GetWindowThreadProcessId(h,out id);var c=new StringBuilder(128);GetClassName(h,c,128); if(Array.IndexOf(pids,id)>=0&&c.ToString()=="Chrome_WidgetWin_0"&&IsWindowVisible(h))result.Add(h.ToInt64()); return true;};
        if(main!=0)EnumChildWindows(new IntPtr(main),cb,IntPtr.Zero);
        EnumWindows(cb,IntPtr.Zero);var a=new long[result.Count];result.CopyTo(a);return a;
    }
}

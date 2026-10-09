namespace CodexQuotaMonitor.Theme {
    using System;
    using System.Runtime.InteropServices;

    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        private struct AccentPolicy {
            public int AccentState;
            public int AccentFlags;
            public int GradientColor;
            public int AnimationId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WindowCompositionAttributeData {
            public int Attribute;
            public IntPtr Data;
            public int SizeOfData;
        }

        [DllImport("user32.dll")]
        private static extern int SetWindowCompositionAttribute(
            IntPtr hwnd,
            ref WindowCompositionAttributeData data
        );

        public static bool EnableBlur(IntPtr hwnd) {
            AccentPolicy policy = new AccentPolicy { AccentState = 3 };
            int size = Marshal.SizeOf(policy);
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(policy, pointer, false);
                WindowCompositionAttributeData data = new WindowCompositionAttributeData {
                    Attribute = 19,
                    Data = pointer,
                    SizeOfData = size
                };
                return SetWindowCompositionAttribute(hwnd, ref data) != 0;
            }
            finally {
                Marshal.FreeHGlobal(pointer);
            }
        }
    }
}

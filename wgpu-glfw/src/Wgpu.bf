using System;
using GLFW;

namespace Wgpu {
	extension Wgpu {
		public static Surface CreateSurfaceFromGlfw(Instance instance, GlfwWindow* window) {
#if BF_PLATFORM_WINDOWS
			{
				Windows.HWnd* hwnd = Glfw.GetWin32Window(window);
				Windows.HModule module = Windows.GetModuleHandleA(null);
	
				Wgpu.SurfaceDescriptorFromWindowsHWND chained = .() {
					chain = .() {
						sType = .SurfaceDescriptorFromWindowsHWND
					},
					hinstance = &module,
					hwnd = hwnd
				};
				Wgpu.SurfaceDescriptor desc = .() {
					nextInChain = (Wgpu.ChainedStruct*) &chained
				};
				return instance.CreateSurface(&desc);
			}
#elif BF_PLATFORM_LINUX
			{
				Glfw.XDisplay* display = Glfw.GetX11Display();
				Glfw.XWindow win = Glfw.GetX11Window(window);

				Wgpu.SurfaceDescriptorFromXlibWindow chained = .() {
					chain = .() {
						sType = .SurfaceDescriptorFromXlibWindow
					},
					display = display,
					window = win
				};
				Wgpu.SurfaceDescriptor desc = .() {
					nextInChain = (Wgpu.ChainedStruct*) &chained
				};
				return instance.CreateSurface(&desc);
			}
#else
#error Unsupported platform
#endif
		}
	}
}
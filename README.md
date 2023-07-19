# WGPU-Beef
**wgpu-beef** is a Beef wrapper library for **WGPU** (more specifically [wgpu-native](https://github.com/gfx-rs/wgpu-native)).  
You can find an example [here](https://github.com/MineGame159/wgpu-beef/blob/master/example/src/Program.bf).

## Notes
- The [core bindings](https://github.com/MineGame15/wgpu-beef/tree/master/src/Wgpu.bf) are automatically generated from latest release.
- Functions are kept as they are but if the function is a method for a struct object handle then a method for that struct is generated too.
- All structs have a default empty constructor (allowing for `.() {}` syntax) and a constructor with all fields.
- There are a few helper functions ported from wgpu-rs (see [Helper.bf](https://github.com/MineGame159/wgpu-beef/blob/master/src/Wgpu.bf)). Pull requests for these helper functions are welcome.
- There is a [glfw compatiblity subproject](https://github.com/MineGame159/wgpu-beef/tree/master/wgpu-glfw) which adds `Wgpu.CreateSurfaceFromGlfw(Wgpu.Instance, GlfwWindow*)` function. (Currently only works on Windows and Linux using X11)
- There is an [ImGui rendering backend subproject](https://github.com/MineGame159/wgpu-beef/tree/master/wgpu-imgui) which adds `ImGuiImplWgpu` static class to the `ImGui` namespace.

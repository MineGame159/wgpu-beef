# WGPU-Beef
**wgpu-beef** is a Beef wrapper library for **WGPU** (more specifically [wgpu-native](https://github.com/gfx-rs/wgpu-native)).  
You can find an example [here](https://github.com/MineGame15/wgpu-beef/tree/master/Example/Program.bf).

## Dev
This branch contains bindings generated from [6d149bf](https://github.com/gfx-rs/wgpu-native/commit/6d149bf3b29c793533cde9ed1dc47c2ba955b324). Only Windows are built using this commit, Linux and MacOs native libraries are the same ones as in master branch.

## Notes
- The [core bindings](https://github.com/MineGame15/wgpu-beef/tree/master/src/Wgpu.bf) are automatically generated from latest release.
- Functions are kept as they are but if the function is a method for a struct object handle then a method for that struct is generated too.
- All structs have a default empty constructor (allowing for `.() {}` syntax) and a constructor with all fields.
- There are a few helper functions ported from wgpu-rs (see [Helper.bf](https://github.com/MineGame15/wgpu-beef/tree/master/src/Helper.bf)). Pull requests for these helper functions are welcome.
- There is a [glfw compatiblity subproject](https://github.com/MineGame15/wgpu-beef/tree/master/wgpu-glfw) which adds `Wgpu.CreateSurfaceFromGlfw(Wgpu.Instance, GlfwWindow*)` function. (Currently only works on Windows and Linux using X11)
- There is an [ImGui rendering backend subproject](https://github.com/MineGame15/wgpu-beef/tree/master/wgpu-glfw/wgpu-imgui) which adds `ImGuiImplWgpu` static class to the `ImGui` namespace.
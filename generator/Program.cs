using System;
using System.IO.Compression;
using CppAst;

// Excuse the bad code here

namespace Generator {
    class Program {
        static readonly Dictionary<string, string> PRIMITIVES = new Dictionary<string, string> {
            ["bool"] = "c_bool",
            ["int"] = "c_int",
            ["char"] = "c_char"
        };

        static readonly Dictionary<string, string> TYPEDEFS = new Dictionary<string, string> {
            ["uint8_t"] = "uint8",
            ["uint16_t"] = "uint16",
            ["uint32_t"] = "uint32",
            ["uint64_t"] = "uint64",

            ["int8_t"] = "int8",
            ["int16_t"] = "int16",
            ["int32_t"] = "int32",
            ["int64_t"] = "int64",

            ["size_t"] = "c_size"
        };

        static readonly (string, string)[] PLATFORMS = {
            ("windows", "dll"),
            ("linux", "so"),
            ("macos", "dylib")
        };

        static readonly string[] BUILDS = {
            "release",
            "debug"
        };

        static void Main() {
            Run().GetAwaiter().GetResult();
        }

        static async Task Run() {
            string version = "0.12.0.1";
            bool local = true;

            // Download native libraries
            string zip1Path = null;
            ZipArchive zip1 = null;

            if (!local) {
                using (var client = new HttpClient()) {
                    foreach (var (platform, extension) in PLATFORMS) {
                        foreach (string build in BUILDS) {
                            string tempPath = Path.GetTempFileName();
                            string outPath = $"../dist/{build}/{platform}/";

                            Directory.CreateDirectory(outPath);

                            using (var stream = await client.GetStreamAsync($"https://github.com/gfx-rs/wgpu-native/releases/download/v{version}/wgpu-{platform}-x86_64-{build}.zip")) {
                                using (var file = new FileStream(tempPath, FileMode.Create)) {
                                    await stream.CopyToAsync(file);
                                }
                            }

                            ZipArchive zip = ZipFile.OpenRead(tempPath);

                            string outFile = outPath + (platform == "windows" ? "wgpu_native" : "libwgpu") + "." + extension;
                            zip.GetEntry("libwgpu." + extension).ExtractToFile(outFile, true);

                            if (platform == "windows") zip.GetEntry("libwgpu.lib").ExtractToFile(outPath + "libwgpu.lib", true);

                            if (platform == "windows" && build == "release") {
                                zip1Path = tempPath;
                                zip1 = zip;
                            }
                            else {
                                zip.Dispose();
                                File.Delete(tempPath);
                            }
                        }
                    }
                }

                // Extract header files
                zip1.GetEntry("wgpu.h").ExtractToFile("wgpu.h", true);
                zip1.GetEntry("webgpu.h").ExtractToFile("webgpu.h", true);
            }

            // Parse headers
            CppCompilation a = CppParser.ParseFile("wgpu.h");

            // Collect structs
            HashSet<string> structs = new HashSet<string>();

            foreach (CppClass klass in a.Classes) {
                string name = klass.Name.Substring(4);
                if (name.EndsWith("Impl")) name = name.Substring(0, name.Length - 4);

                structs.Add(name);
            }

            // Collect methods
            Dictionary<string, List<CppFunction>> methods = new Dictionary<string, List<CppFunction>>();

            foreach (CppFunction function in a.Functions) {
                string name = function.Name.Substring(4);
                string? structName = null;

                foreach (string s in structs) {
                    if (name.StartsWith(s)) {
                        if (structName == null || s.Length > structName.Length) structName = s;
                    }
                }

                if (structName == null) continue;

                CppParameter parameter = function.Parameters[0];
                if (parameter.Type.TypeKind != CppTypeKind.Typedef) continue;
                if ((parameter.Type as CppTypedef).ElementType.TypeKind != CppTypeKind.Pointer) continue;
                if (((parameter.Type as CppTypedef).ElementType as CppPointerType).ElementType.TypeKind != CppTypeKind.StructOrClass) continue;
                
                string n = (((parameter.Type as CppTypedef).ElementType as CppPointerType).ElementType as CppClass).Name.Substring(4);
                if (n.EndsWith("Impl")) n = n.Substring(0, n.Length - 4);
                if (n != structName) continue;

                List<CppFunction> functions = methods.GetValueOrDefault(structName, null);
                if (functions == null) {
                    functions = new List<CppFunction>();
                    methods[structName] = functions;
                }
                functions.Add(function);
            }

            // Generate bindings
            using (StreamWriter w = new StreamWriter("../src/Wgpu.bf", false)) {
                w.WriteLine("// --------------- DO NOT EDIT --------------");
                w.WriteLine("// -- This file is automatically generated --");
                w.WriteLine("//");
                w.WriteLine("// Date: " + DateTime.Now);
                w.WriteLine("// Enums: " + a.Enums.Count);
                w.WriteLine("// Structs: " + a.Classes.Count);
                w.WriteLine("// Functions: " + a.Functions.Count);
                w.WriteLine();

                w.WriteLine("using System;");
                w.WriteLine("using System.Interop;");
                w.WriteLine();
                w.WriteLine("namespace Wgpu {");
                w.WriteLine("\tpublic static class Wgpu {");

                for (int i = 0; i < a.Enums.Count; i++) {
                    if (i > 0) w.WriteLine();
                    GenerateEnum(w, a.Enums[i]);
                }

                foreach (CppClass klass in a.Classes) {
                    w.WriteLine();

                    string name = klass.Name.Substring(4);
                    if (name.EndsWith("Impl")) name = name.Substring(0, name.Length - 4);

                    GenerateClass(w, klass, methods.GetValueOrDefault(name, null));
                }

                w.WriteLine();
                foreach (CppTypedef typedef in a.Typedefs) {
                    GenerateTypedef(w, typedef);
                }

                foreach (CppFunction function in a.Functions) {
                    w.WriteLine();
                    GenerateFunction(w, function);
                }

                w.WriteLine("\t}");
                w.WriteLine("}");
            }

            // Delete headers and temp zip
            if (!local) {
                File.Delete("wgpu.h");
                File.Delete("webgpu.h");

                zip1.Dispose();
                File.Delete(zip1Path);
            }
        }

        static void GenerateEnum(StreamWriter w, CppEnum e) {
            w.WriteLine("\t\tpublic enum " + e.Name.Substring(4) + " : c_uint {");

            foreach (CppEnumItem item in e.Items) {
                string name = item.Name.Substring(item.Name.IndexOf('_') + 1);
                if (name == "Force32") continue;

                if (char.IsDigit(name[0])) name = "_" + name;

                w.WriteLine("\t\t\t" + name + " = " + item.Value + ",");
            }

            w.WriteLine("\t\t}");
        }

        static void GenerateClass(StreamWriter w, CppClass klass, List<CppFunction> functions) {
            w.WriteLine("\t\t[CRepr]");

            string name = klass.Name.Substring(4);
            bool impl = name.EndsWith("Impl");

            if (impl) {
                name = name.Substring(0, name.Length - 4);

                w.WriteLine("\t\tpublic struct " + name + " : this(void* Handle) {");
                w.WriteLine("\t\t\tpublic static Self Null => .(null);");

                if (klass.Fields.Count != 0) w.WriteLine();
            }
            else {
                w.WriteLine("\t\tpublic struct " + name + " {");
            }
            
            foreach (CppField field in klass.Fields) {
                string? type = GetType(field.Type);
                if (type != null) w.WriteLine("\t\t\tpublic " + type + " " + field.Name + ";");
            }

            if (!impl) {
                w.WriteLine();

                w.WriteLine("\t\t\tpublic this() {");
                w.WriteLine("\t\t\t\tthis = default;");
                w.WriteLine("\t\t\t}");
                w.WriteLine();

                w.Write("\t\t\tpublic this(");
                for (int i = 0; i < klass.Fields.Count; i++) {
                    if (i > 0) w.Write(", ");
                    w.Write(GetType(klass.Fields[i].Type) + " " + klass.Fields[i].Name);
                }
                w.WriteLine(") {");
                foreach (CppField field in klass.Fields) {
                    w.WriteLine("\t\t\t\tthis." + field.Name + " = " + field.Name + ";");
                }
                w.WriteLine("\t\t\t}");
            }

            if (functions != null) {
                w.WriteLine();

                foreach (CppFunction function in functions) {
                    string? returnType = GetType(function.ReturnType);
                    if (returnType == null) continue;

                    w.Write("\t\t\tpublic " + returnType + " " + function.Name.Substring(4 + name.Length) + "(");

                    for (int i = 1; i < function.Parameters.Count; i++) {
                        CppParameter parameter = function.Parameters[i];

                        string? type = GetType(parameter.Type);
                        if (type == null) continue;

                        if (i > 1) w.Write(", ");
                        w.Write(type + " " + parameter.Name);
                    }
                    w.Write(") => Wgpu." + function.Name.Substring(4) + "(this");
                    for (int i = 1; i < function.Parameters.Count; i++) {
                        w.Write(", " + function.Parameters[i].Name);
                    }
                    w.WriteLine(");");
                }
            }

            w.WriteLine("\t\t}");
        }

        static void GenerateTypedef(StreamWriter w, CppTypedef typedef) {
            if (typedef.ElementType.TypeKind == CppTypeKind.Pointer) {
                CppPointerType pointer = typedef.ElementType as CppPointerType;

                if (pointer.ElementType.TypeKind == CppTypeKind.StructOrClass) {
                    if ((pointer.ElementType as CppClass).Name.EndsWith("Impl")) return;
                }

                if (pointer.ElementType.TypeKind == CppTypeKind.Function) {
                    CppFunctionType function = pointer.ElementType as CppFunctionType;

                    string? returnType = GetType(function.ReturnType);
                    if (returnType == null) return;

                    w.Write("\t\tpublic function " + returnType + " " + typedef.Name.Substring(4) + "(");

                    for (int i = 0; i < function.Parameters.Count; i++) {
                        if (i > 0) w.Write(", ");

                        string? t = GetType(function.Parameters[i].Type);
                        if (t == null) return;

                        w.Write(t + " " + function.Parameters[i].Name);
                    }

                    w.WriteLine(");");
                    return;
                }
            }

            string name = typedef.Name.Substring(4);
            if (name == "Flags") return;

            string? type = GetType(typedef.ElementType);
            if (type == "") return;

            if (type != null) w.WriteLine("\t\tpublic typealias " + name + " = " + type + ";");
        }

        static void GenerateFunction(StreamWriter w, CppFunction function) {
            string? returnType = GetType(function.ReturnType);
            if (returnType == null) return;

            w.WriteLine("\t\t[LinkName(\"" + function.Name + "\")]");
            w.Write("\t\tpublic static extern " + returnType + " " + function.Name.Substring(4) + "(");

            for (int i = 0; i < function.Parameters.Count; i++) {
                if (i > 0) w.Write(", ");

                string? t = GetType(function.Parameters[i].Type);
                if (t == null) return;

                w.Write(t + " " + function.Parameters[i].Name);
            }

            w.WriteLine(");");
        }

        static string? GetType(CppType type) {
            string? str = null;

            switch (type.TypeKind)
            {
                case CppTypeKind.Primitive:
                    str = type.ToString();
                    str = PRIMITIVES.GetValueOrDefault(str, str);
                    break;
                case CppTypeKind.Pointer:
                    str = GetType((type as CppPointerType).ElementType);
                    if (str != null) str += "*";
                    break;
                case CppTypeKind.Qualified:
                    str = GetType((type as CppQualifiedType).ElementType);
                    break;
                /*case CppTypeKind.Function:
                    Console.WriteLine(type);
                    break;*/
                case CppTypeKind.Typedef:
                    str = (type as CppTypedef).Name;
                    if (str.StartsWith("WGPU")) str = str.Substring(4);
                    if (str.EndsWith("Flags")) str = str.Substring(0, str.Length - 5);
                    str = TYPEDEFS.GetValueOrDefault(str, str);
                    break;
                case CppTypeKind.StructOrClass:
                    str = (type as CppClass).Name.Substring(4);
                    break;
                case CppTypeKind.Enum:
                    str = (type as CppEnum).Name.Substring(4);
                    break;
                default:
                    Console.WriteLine("Unknown type: " + type.TypeKind);
                    break;
            }

            return str;
        }
    }
}
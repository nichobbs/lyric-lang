// std/_kernel/reflection_host.l — host boundary for compile-time reflection.
//
// Used by the self-hosted MSIL emitter (`Msil.Ffi`) to resolve
// `@externTarget("Type.Member")` declarations against the BCL
// assemblies loaded into the compiler's own AppDomain.  The Lyric
// self-hosted compiler runs on .NET, so it has access to
// System.Reflection in-process; this kernel exposes the bits the FFI
// resolver needs.
//
// Internal: only the self-hosted compiler should import this.  User
// programs should not — runtime reflection is intentionally outside
// the stable surface.

@axiom("System.Reflection operations conform to their documented .NET contracts")
package Std.ReflectionHost

import Std.Core

// ── Extern types ──────────────────────────────────────────────────────────────

extern type ClrType         = "System.Type"
extern type ClrAssembly     = "System.Reflection.Assembly"
extern type ClrMethodInfo   = "System.Reflection.MethodInfo"
extern type ClrCtorInfo     = "System.Reflection.ConstructorInfo"
extern type ClrFieldInfo    = "System.Reflection.FieldInfo"
extern type ClrPropertyInfo = "System.Reflection.PropertyInfo"
extern type ClrParamInfo    = "System.Reflection.ParameterInfo"
extern type ClrAssemblyName = "System.Reflection.AssemblyName"
extern type ClrAppDomain    = "System.AppDomain"

// ── Type lookup ──────────────────────────────────────────────────────────────

// Resolve a fully-qualified CLR type name (e.g. "System.Net.Http.HttpClient")
// against the calling AppDomain's loaded assemblies.  Returns null when
// the type is unknown.  Mirrors System.Type.GetType(string).
@externTarget("System.Type.GetType")
pub func typeGetType(qualifiedName: in String): ClrType? = ()

// Walk every loaded assembly in the current AppDomain and return the
// first one that defines a type with the given full name.  Used as a
// fallback when System.Type.GetType returns null.
@externTarget("System.AppDomain.CurrentDomain")
pub func currentDomain(): ClrAppDomain = ()

@externTarget("System.AppDomain.GetAssemblies")
pub func domainAssemblies(domain: in ClrAppDomain): slice[ClrAssembly] = ()

@externTarget("System.Reflection.Assembly.GetType")
pub func assemblyGetType(asm: in ClrAssembly, fullName: in String): ClrType? = ()

// ── Type → Assembly ──────────────────────────────────────────────────────────

@externTarget("System.Type.Assembly")
pub func typeAssembly(t: in ClrType): ClrAssembly = ()

@externTarget("System.Reflection.Assembly.GetName")
pub func assemblyGetName(asm: in ClrAssembly): ClrAssemblyName = ()

@externTarget("System.Reflection.AssemblyName.Name")
pub func assemblyNameName(n: in ClrAssemblyName): String = ()

// ── Type metadata ────────────────────────────────────────────────────────────

@externTarget("System.Type.FullName")
pub func typeFullName(t: in ClrType): String = ()

@externTarget("System.Type.Namespace")
pub func typeNamespace(t: in ClrType): String = ()

@externTarget("System.Type.Name")
pub func typeName(t: in ClrType): String = ()

@externTarget("System.Type.IsValueType")
pub func typeIsValueType(t: in ClrType): Bool = ()

// ── Method lookup ────────────────────────────────────────────────────────────

@externTarget("System.Type.GetMethods")
pub func typeGetMethods(t: in ClrType): slice[ClrMethodInfo] = ()

@externTarget("System.Type.GetConstructors")
pub func typeGetConstructors(t: in ClrType): slice[ClrCtorInfo] = ()

@externTarget("System.Reflection.MethodInfo.Name")
pub func methodName(m: in ClrMethodInfo): String = ()

@externTarget("System.Reflection.MethodInfo.IsStatic")
pub func methodIsStatic(m: in ClrMethodInfo): Bool = ()

@externTarget("System.Reflection.MethodInfo.IsVirtual")
pub func methodIsVirtual(m: in ClrMethodInfo): Bool = ()

@externTarget("System.Reflection.MethodInfo.GetParameters")
pub func methodGetParameters(m: in ClrMethodInfo): slice[ClrParamInfo] = ()

@externTarget("System.Reflection.MethodInfo.ReturnType")
pub func methodReturnType(m: in ClrMethodInfo): ClrType = ()

@externTarget("System.Reflection.ConstructorInfo.GetParameters")
pub func ctorGetParameters(c: in ClrCtorInfo): slice[ClrParamInfo] = ()

@externTarget("System.Reflection.ParameterInfo.ParameterType")
pub func paramType(p: in ClrParamInfo): ClrType = ()

@externTarget("System.Reflection.ParameterInfo.HasDefaultValue")
pub func paramHasDefaultValue(p: in ClrParamInfo): Bool = ()

// ── Field / property lookup ──────────────────────────────────────────────────

@externTarget("System.Type.GetField")
pub func typeGetField(t: in ClrType, name: in String): ClrFieldInfo? = ()

@externTarget("System.Type.GetProperty")
pub func typeGetProperty(t: in ClrType, name: in String): ClrPropertyInfo? = ()

@externTarget("System.Reflection.FieldInfo.IsStatic")
pub func fieldIsStatic(f: in ClrFieldInfo): Bool = ()

@externTarget("System.Reflection.FieldInfo.FieldType")
pub func fieldType(f: in ClrFieldInfo): ClrType = ()

@externTarget("System.Reflection.PropertyInfo.CanRead")
pub func propertyCanRead(p: in ClrPropertyInfo): Bool = ()

@externTarget("System.Reflection.PropertyInfo.GetGetMethod")
pub func propertyGetGetMethod(p: in ClrPropertyInfo): ClrMethodInfo? = ()

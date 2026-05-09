package lyric.resolver;

import org.objectweb.asm.*;

import java.util.ArrayList;
import java.util.List;

/**
 * ASM-based class file scanner for public class surface extraction.
 *
 * <p>Reads a single {@code .class} file's bytecode and returns a
 * {@link MavenResolver.ClassInfo} describing its public static methods
 * with translatable signatures.  Returns {@code null} for:
 * <ul>
 *   <li>Non-public classes / interfaces / enums / annotations.
 *   <li>Classes with generic type parameters (bootstrap-grade limit).
 * </ul>
 *
 * <p>Type translation follows docs/31-maven-linking.md §6 bootstrap scope:
 * Java primitives and {@code java.lang.String} → Lyric scalars; anything
 * else must be another public class in the same JAR (resolved by the
 * caller).  Generic types, arrays, and void (except as return) are skip
 * reasons rather than hard errors.
 */
final class ClassScanner extends ClassVisitor {

    private static final int API = Opcodes.ASM9;

    private String className;
    private boolean skip = false;
    private final List<MavenResolver.MethodInfo> methods = new ArrayList<>();

    private ClassScanner() {
        super(API);
    }

    /** Scan {@code classBytes} and return the class surface, or {@code null}. */
    static MavenResolver.ClassInfo scan(byte[] classBytes) {
        ClassScanner scanner = new ClassScanner();
        ClassReader cr = new ClassReader(classBytes);
        cr.accept(scanner, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
        if (scanner.skip || scanner.className == null) return null;
        if (scanner.methods.isEmpty()) return null;

        MavenResolver.ClassInfo ci = new MavenResolver.ClassInfo();
        ci.className = scanner.className;
        ci.methods = scanner.methods;
        return ci;
    }

    @Override
    public void visit(int version, int access, String name, String signature,
                      String superName, String[] interfaces) {
        // Skip: non-public, abstract (no useful instances), interface,
        // annotation, enum, or generic (bootstrap limit).
        if ((access & Opcodes.ACC_PUBLIC) == 0
                || (access & Opcodes.ACC_INTERFACE) != 0
                || (access & Opcodes.ACC_ANNOTATION) != 0
                || (access & Opcodes.ACC_ENUM) != 0
                || signature != null) {   // generic class signature present
            skip = true;
            return;
        }
        this.className = name.replace('/', '.');
    }

    @Override
    public MethodVisitor visitMethod(int access, String name, String descriptor,
                                     String signature, String[] exceptions) {
        if (skip) return null;
        // Only public static methods; skip synthetic/bridge/constructor.
        if ((access & Opcodes.ACC_PUBLIC) == 0) return null;
        if ((access & Opcodes.ACC_SYNTHETIC) != 0) return null;
        if ((access & Opcodes.ACC_BRIDGE) != 0) return null;
        if ("<init>".equals(name) || "<clinit>".equals(name)) return null;
        // Skip generic methods.
        if (signature != null) return null;

        boolean isStatic = (access & Opcodes.ACC_STATIC) != 0;

        // Parse the descriptor to extract parameter + return types.
        Type methodType = Type.getMethodType(descriptor);
        String returnTypeName = javaTypeName(methodType.getReturnType());
        if (returnTypeName == null) return null;  // untranslatable return

        Type[] argTypes = methodType.getArgumentTypes();
        List<MavenResolver.ParamInfo> params = new ArrayList<>();
        for (int i = 0; i < argTypes.length; i++) {
            String typeName = javaTypeName(argTypes[i]);
            if (typeName == null) return null;   // untranslatable param → skip method
            MavenResolver.ParamInfo pi = new MavenResolver.ParamInfo();
            // Bytecode doesn't always carry parameter names; fall back to
            // positional names that MavenShim.fs handles gracefully.
            pi.name = "arg" + i;
            pi.typeName = typeName;
            params.add(pi);
        }

        MavenResolver.MethodInfo mi = new MavenResolver.MethodInfo();
        mi.name = name;
        mi.returnType = returnTypeName;
        mi.isStatic = isStatic;
        mi.params = params;
        methods.add(mi);
        return null;
    }

    /**
     * Map an ASM {@link Type} to a Java binary type name string used by
     * {@link MavenResolver.MavenShim}.  Returns {@code null} for types
     * the bootstrap shim generator can't translate (arrays, generics,
     * complex objects not already in the JAR's own surface).
     */
    private static String javaTypeName(Type t) {
        return switch (t.getSort()) {
            case Type.BOOLEAN -> "boolean";
            case Type.BYTE    -> "byte";
            case Type.CHAR    -> "char";
            case Type.SHORT   -> "short";
            case Type.INT     -> "int";
            case Type.LONG    -> "long";
            case Type.FLOAT   -> "float";
            case Type.DOUBLE  -> "double";
            case Type.VOID    -> "void";
            case Type.OBJECT  -> t.getClassName();   // fully-qualified
            case Type.ARRAY   -> null;               // skip
            default           -> null;
        };
    }
}

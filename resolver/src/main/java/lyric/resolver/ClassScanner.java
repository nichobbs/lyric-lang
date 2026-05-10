package lyric.resolver;

import org.objectweb.asm.*;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * ASM-based class file scanner for public class surface extraction.
 *
 * <p>Reads a single {@code .class} file's bytecode and returns a
 * {@link MavenResolver.ClassInfo} describing its public methods
 * (both static and instance) with translatable signatures.  Returns
 * {@code null} for:
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
 *
 * <p>Checked-exception detection: a method has {@code hasCheckedExceptions=true}
 * when its {@code throws} clause contains at least one type that is not a
 * known subclass of {@code RuntimeException} or {@code Error}.  The
 * conservative set of known-unchecked names is sufficient for all common
 * Java standard-library exception roots.
 */
final class ClassScanner extends ClassVisitor {

    private static final int API = Opcodes.ASM9;

    // Known-unchecked exception fully-qualified names.  Anything in the
    // throws clause not in this set is treated as a checked exception.
    private static final Set<String> KNOWN_UNCHECKED = Set.of(
        "java.lang.RuntimeException",
        "java.lang.Error",
        "java.lang.Throwable",
        "java.lang.IllegalArgumentException",
        "java.lang.IllegalStateException",
        "java.lang.NullPointerException",
        "java.lang.UnsupportedOperationException",
        "java.lang.IndexOutOfBoundsException",
        "java.lang.ArrayIndexOutOfBoundsException",
        "java.lang.StringIndexOutOfBoundsException",
        "java.lang.ArithmeticException",
        "java.lang.ClassCastException",
        "java.lang.AssertionError",
        "java.lang.StackOverflowError",
        "java.lang.OutOfMemoryError",
        "java.lang.NumberFormatException",
        "java.lang.ConcurrentModificationException",
        "java.util.NoSuchElementException"
    );

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
        // Skip: non-public, interface, annotation, enum, or generic.
        if ((access & Opcodes.ACC_PUBLIC) == 0
                || (access & Opcodes.ACC_INTERFACE) != 0
                || (access & Opcodes.ACC_ANNOTATION) != 0
                || (access & Opcodes.ACC_ENUM) != 0
                || signature != null) {
            skip = true;
            return;
        }
        this.className = name.replace('/', '.');
    }

    @Override
    public MethodVisitor visitMethod(int access, String name, String descriptor,
                                     String signature, String[] exceptions) {
        if (skip) return null;
        // Only public methods; skip synthetic/bridge/static-initializer/constructors.
        if ((access & Opcodes.ACC_PUBLIC) == 0) return null;
        if ((access & Opcodes.ACC_SYNTHETIC) != 0) return null;
        if ((access & Opcodes.ACC_BRIDGE) != 0) return null;
        if ("<init>".equals(name) || "<clinit>".equals(name)) return null;
        // Skip generic methods.
        if (signature != null) return null;

        boolean isStatic = (access & Opcodes.ACC_STATIC) != 0;
        boolean hasChecked = hasCheckedExceptions(exceptions);

        // Parse the descriptor to extract parameter + return types.
        Type methodType = Type.getMethodType(descriptor);
        String returnTypeName = javaTypeName(methodType.getReturnType());
        if (returnTypeName == null) return null;  // untranslatable return

        Type[] argTypes = methodType.getArgumentTypes();
        List<MavenResolver.ParamInfo> params = new ArrayList<>();
        for (int i = 0; i < argTypes.length; i++) {
            String typeName = javaTypeName(argTypes[i]);
            if (typeName == null) return null;  // untranslatable param → skip method
            MavenResolver.ParamInfo pi = new MavenResolver.ParamInfo();
            pi.name = "arg" + i;
            pi.typeName = typeName;
            params.add(pi);
        }

        MavenResolver.MethodInfo mi = new MavenResolver.MethodInfo();
        mi.name = name;
        mi.returnType = returnTypeName;
        mi.isStatic = isStatic;
        mi.hasCheckedExceptions = hasChecked;
        mi.params = params;
        methods.add(mi);
        return null;
    }

    /** Returns true if the throws clause contains at least one checked exception. */
    private static boolean hasCheckedExceptions(String[] exceptions) {
        if (exceptions == null || exceptions.length == 0) return false;
        for (String e : exceptions) {
            if (!KNOWN_UNCHECKED.contains(e.replace('/', '.'))) return true;
        }
        return false;
    }

    /**
     * Map an ASM {@link Type} to a Java binary type name string used by
     * the shim generator.  Returns {@code null} for types that cannot be
     * translated (arrays, generics, complex objects not in the JAR surface).
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
            case Type.OBJECT  -> t.getClassName();
            case Type.ARRAY   -> null;
            default           -> null;
        };
    }
}

// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.Base64;

/** The encoders and decoders of the scalar boundary types (D207 Decision 4). */
public final class Wire {
    private Wire() {}

    private static final BigInteger LONG_MIN = BigInteger.valueOf(Long.MIN_VALUE);
    private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);
    private static final BigInteger ULONG_MAX = new BigInteger("18446744073709551615");

    private static ProtocolException kind(String path, String expected, Json.Value j) {
        return new ProtocolException(path + ": expected " + expected + ", found " + kindName(j));
    }

    private static String kindName(Json.Value j) {
        if (j == null) return "nothing";
        if (j instanceof Json.Null) return "null";
        if (j instanceof Json.Bool) return "a boolean";
        if (j instanceof Json.Num) return "a number";
        if (j instanceof Json.Str) return "a string";
        if (j instanceof Json.Arr) return "an array";
        return "an object";
    }

    public static Json.Obj expectObject(Json.Value j, String path) {
        if (j instanceof Json.Obj o) return o;
        throw kind(path, "an object", j);
    }

    public static Json.Arr expectArray(Json.Value j, String path) {
        if (j instanceof Json.Arr a) return a;
        throw kind(path, "an array", j);
    }

    public static Json.Arr expectTuple(Json.Value j, String path, int count) {
        Json.Arr a = expectArray(j, path);
        if (a.items().size() != count) {
            throw new ProtocolException(path + ": expected an array of " + count + " elements, found " + a.items().size());
        }
        return a;
    }

    public static boolean has(Json.Obj o, String name) { return o.has(name); }

    public static Json.Value required(Json.Obj o, String name, String path) {
        if (!o.has(name)) throw new ProtocolException(path + ": missing required member \"" + name + "\"");
        return o.get(name);
    }

    public static String caseName(Json.Obj o, String path) {
        return decodeString(required(o, "case", path), path + ".case");
    }

    public static ProtocolException unknownCase(String path, String typeName, String name) {
        return new ProtocolException(path + ": \"" + name + "\" is not a case of " + typeName);
    }

    private static BigInteger integer(Json.Value j, String path, String expected) {
        if (j instanceof Json.Num n) {
            String raw = n.raw();
            boolean plain = !raw.contains(".") && !raw.contains("e") && !raw.contains("E");
            if (plain) return new BigInteger(raw);
            throw new ProtocolException(path + ": expected " + expected + ", found the non-integer " + raw);
        }
        throw kind(path, expected, j);
    }

    private static long ranged(Json.Value j, String path, String expected, BigInteger min, BigInteger max) {
        BigInteger v = integer(j, path, expected);
        if (v.compareTo(min) < 0 || v.compareTo(max) > 0) {
            throw new ProtocolException(path + ": " + v + " is out of range for " + expected);
        }
        return v.longValue();
    }

    public static Json.Value encodeBool(boolean v) { return new Json.Bool(v); }

    public static boolean decodeBool(Json.Value j, String path) {
        if (j instanceof Json.Bool b) return b.value();
        throw kind(path, "a boolean", j);
    }

    public static Json.Value encodeByte(int v) {
        if (v < 0 || v > 255) throw new ProtocolException("a Byte must be 0 to 255, found " + v);
        return new Json.Num(Integer.toString(v));
    }

    public static int decodeByte(Json.Value j, String path) {
        return (int) ranged(j, path, "a Byte (0 to 255)", BigInteger.ZERO, BigInteger.valueOf(255));
    }

    public static Json.Value encodeInt(int v) { return new Json.Num(Integer.toString(v)); }

    public static int decodeInt(Json.Value j, String path) {
        return (int) ranged(j, path, "an Int (a 32-bit integer)", BigInteger.valueOf(Integer.MIN_VALUE), BigInteger.valueOf(Integer.MAX_VALUE));
    }

    public static Json.Value encodeLong(long v) { return new Json.Num(Long.toString(v)); }

    public static long decodeLong(Json.Value j, String path) {
        return ranged(j, path, "a Long (a 64-bit integer)", LONG_MIN, LONG_MAX);
    }

    public static Json.Value encodeUInt(long v) {
        if (v < 0 || v > 4294967295L) throw new ProtocolException("a UInt must be 0 to 4294967295, found " + v);
        return new Json.Num(Long.toString(v));
    }

    public static long decodeUInt(Json.Value j, String path) {
        return ranged(j, path, "a UInt (0 to 4294967295)", BigInteger.ZERO, BigInteger.valueOf(4294967295L));
    }

    /** A ULong travels in a Java {@code long} holding its 64 bits (see {@link Long#toUnsignedString}). */
    public static Json.Value encodeULong(long v) { return new Json.Num(Long.toUnsignedString(v)); }

    public static long decodeULong(Json.Value j, String path) {
        return ranged(j, path, "a ULong (0 to 18446744073709551615)", BigInteger.ZERO, ULONG_MAX);
    }

    public static Json.Value encodeFloat(float v) {
        if (!Float.isFinite(v)) throw new ProtocolException("a non-finite Float cannot be encoded as JSON");
        return new Json.Num(new BigDecimal(Float.toString(v)).toString());
    }

    public static float decodeFloat(Json.Value j, String path) {
        if (j instanceof Json.Num n) {
            float f = Float.parseFloat(n.raw());
            if (Float.isFinite(f)) return f;
            throw new ProtocolException(path + ": " + n.raw() + " is out of range for a Float");
        }
        throw kind(path, "a Float", j);
    }

    public static Json.Value encodeDouble(double v) {
        if (!Double.isFinite(v)) throw new ProtocolException("a non-finite Double cannot be encoded as JSON");
        return new Json.Num(new BigDecimal(Double.toString(v)).toString());
    }

    public static double decodeDouble(Json.Value j, String path) {
        if (j instanceof Json.Num n) {
            double d = Double.parseDouble(n.raw());
            if (Double.isFinite(d)) return d;
            throw new ProtocolException(path + ": " + n.raw() + " is out of range for a Double");
        }
        throw kind(path, "a Double", j);
    }

    public static Json.Value encodeChar(char v) { return new Json.Str(String.valueOf(v)); }

    public static char decodeChar(Json.Value j, String path) {
        String s = decodeString(j, path);
        if (s.length() != 1 || Character.isSurrogate(s.charAt(0))) {
            throw new ProtocolException(path + ": expected a one-character string");
        }
        return s.charAt(0);
    }

    public static Json.Value encodeString(String v) {
        if (v == null) throw new ProtocolException("a String must not be null");
        return new Json.Str(v);
    }

    public static String decodeString(Json.Value j, String path) {
        if (j instanceof Json.Str s) return s.value();
        throw kind(path, "a string", j);
    }

    public static Json.Value encodeUnit(Unit v) { return Json.NULL; }

    public static Unit decodeUnit(Json.Value j, String path) {
        if (j instanceof Json.Null) return Unit.UNIT;
        throw kind(path, "null", j);
    }

    public static Json.Value encodeBytes(byte[] v) { return new Json.Str(Base64.getEncoder().encodeToString(v)); }

    public static byte[] decodeBytes(Json.Value j, String path) {
        String s = decodeString(j, path);
        try {
            return Base64.getDecoder().decode(s);
        } catch (IllegalArgumentException e) {
            throw new ProtocolException(path + ": not a base64 string");
        }
    }

    public static Json.Value encodeJson(Json.Value v) { return v == null ? Json.NULL : v; }

    public static Json.Value decodeJson(Json.Value j, String path) { return j == null ? Json.NULL : j; }
}

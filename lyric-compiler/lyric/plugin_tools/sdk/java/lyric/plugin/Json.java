// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A strict RFC 8259 JSON value model with a parser and a writer. Numbers keep
 * their source text, so integers of any size are read exactly.
 */
public final class Json {
    private Json() {}

    /** A JSON value. */
    public sealed interface Value permits Null, Bool, Num, Str, Arr, Obj {}

    /** {@code null}. */
    public enum Null implements Value { NULL }

    /** {@code true} or {@code false}. */
    public record Bool(boolean value) implements Value {}

    /** A number, as its JSON text. */
    public record Num(String raw) implements Value {
        public static Num of(long v) { return new Num(Long.toString(v)); }
    }

    /** A string. */
    public record Str(String value) implements Value {}

    /** An array. */
    public record Arr(List<Value> items) implements Value {
        public Arr() { this(new ArrayList<>()); }
    }

    /** An object; members keep their order. */
    public record Obj(LinkedHashMap<String, Value> members) implements Value {
        public Obj() { this(new LinkedHashMap<>()); }

        public Obj put(String name, Value value) {
            members.put(name, value);
            return this;
        }

        public boolean has(String name) { return members.containsKey(name); }

        public Value get(String name) { return members.get(name); }
    }

    public static final Value NULL = Null.NULL;

    public static Value str(String s) { return new Str(s); }

    public static Value bool(boolean b) { return new Bool(b); }

    /** Parses one JSON document. */
    public static Value parse(String text) {
        Parser p = new Parser(text);
        p.ws();
        Value v = p.value(0);
        p.ws();
        if (p.pos != text.length()) throw new IllegalArgumentException("trailing content at position " + p.pos);
        return v;
    }

    /** Writes compact JSON text. */
    public static String write(Value v) {
        StringBuilder sb = new StringBuilder();
        write(sb, v);
        return sb.toString();
    }

    private static void write(StringBuilder sb, Value v) {
        if (v instanceof Null) {
            sb.append("null");
        } else if (v instanceof Bool b) {
            sb.append(b.value() ? "true" : "false");
        } else if (v instanceof Num n) {
            sb.append(n.raw());
        } else if (v instanceof Str s) {
            quote(sb, s.value());
        } else if (v instanceof Arr a) {
            sb.append('[');
            for (int i = 0; i < a.items().size(); i++) {
                if (i > 0) sb.append(',');
                write(sb, a.items().get(i));
            }
            sb.append(']');
        } else if (v instanceof Obj o) {
            sb.append('{');
            boolean first = true;
            for (Map.Entry<String, Value> e : o.members().entrySet()) {
                if (!first) sb.append(',');
                first = false;
                quote(sb, e.getKey());
                sb.append(':');
                write(sb, e.getValue());
            }
            sb.append('}');
        }
    }

    private static void quote(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                case '\b' -> sb.append("\\b");
                case '\f' -> sb.append("\\f");
                default -> {
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
                }
            }
        }
        sb.append('"');
    }

    private static final class Parser {
        private static final int MAX_DEPTH = 128;
        final String s;
        int pos;

        Parser(String s) { this.s = s; }

        IllegalArgumentException fail(String expected) {
            return new IllegalArgumentException("expected " + expected + " at position " + pos);
        }

        void ws() {
            while (pos < s.length()) {
                char c = s.charAt(pos);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') pos++;
                else break;
            }
        }

        boolean lit(String word) {
            if (s.startsWith(word, pos)) {
                pos += word.length();
                return true;
            }
            return false;
        }

        Value value(int depth) {
            if (depth > MAX_DEPTH) throw new IllegalArgumentException("document nested deeper than " + MAX_DEPTH);
            if (pos >= s.length()) throw fail("a value");
            char c = s.charAt(pos);
            if (c == '{') return object(depth);
            if (c == '[') return array(depth);
            if (c == '"') return new Str(string());
            if (lit("true")) return new Bool(true);
            if (lit("false")) return new Bool(false);
            if (lit("null")) return NULL;
            if (c == '-' || (c >= '0' && c <= '9')) return number();
            throw fail("a value");
        }

        Value object(int depth) {
            pos++;
            Obj o = new Obj();
            ws();
            if (pos < s.length() && s.charAt(pos) == '}') {
                pos++;
                return o;
            }
            while (true) {
                ws();
                if (pos >= s.length() || s.charAt(pos) != '"') throw fail("a member name");
                String name = string();
                ws();
                if (pos >= s.length() || s.charAt(pos) != ':') throw fail("':'");
                pos++;
                ws();
                o.members().put(name, value(depth + 1));
                ws();
                if (pos < s.length() && s.charAt(pos) == ',') {
                    pos++;
                    continue;
                }
                if (pos < s.length() && s.charAt(pos) == '}') {
                    pos++;
                    return o;
                }
                throw fail("',' or '}'");
            }
        }

        Value array(int depth) {
            pos++;
            Arr a = new Arr();
            ws();
            if (pos < s.length() && s.charAt(pos) == ']') {
                pos++;
                return a;
            }
            while (true) {
                ws();
                a.items().add(value(depth + 1));
                ws();
                if (pos < s.length() && s.charAt(pos) == ',') {
                    pos++;
                    continue;
                }
                if (pos < s.length() && s.charAt(pos) == ']') {
                    pos++;
                    return a;
                }
                throw fail("',' or ']'");
            }
        }

        String string() {
            pos++;
            StringBuilder sb = new StringBuilder();
            while (true) {
                if (pos >= s.length()) throw fail("'\"'");
                char c = s.charAt(pos++);
                if (c == '"') return sb.toString();
                if (c < 0x20) throw new IllegalArgumentException("control character in a string at position " + (pos - 1));
                if (c != '\\') {
                    sb.append(c);
                    continue;
                }
                if (pos >= s.length()) throw fail("an escape");
                char e = s.charAt(pos++);
                switch (e) {
                    case '"' -> sb.append('"');
                    case '\\' -> sb.append('\\');
                    case '/' -> sb.append('/');
                    case 'b' -> sb.append('\b');
                    case 'f' -> sb.append('\f');
                    case 'n' -> sb.append('\n');
                    case 'r' -> sb.append('\r');
                    case 't' -> sb.append('\t');
                    case 'u' -> {
                        if (pos + 4 > s.length()) throw fail("four hex digits");
                        int cp;
                        try {
                            cp = Integer.parseInt(s.substring(pos, pos + 4), 16);
                        } catch (NumberFormatException ex) {
                            throw fail("four hex digits");
                        }
                        pos += 4;
                        sb.append((char) cp);
                    }
                    default -> throw fail("an escape");
                }
            }
        }

        Value number() {
            int start = pos;
            if (s.charAt(pos) == '-') pos++;
            if (pos >= s.length()) throw fail("a digit");
            if (s.charAt(pos) == '0') {
                pos++;
            } else if (s.charAt(pos) >= '1' && s.charAt(pos) <= '9') {
                while (pos < s.length() && Character.isDigit(s.charAt(pos)) && s.charAt(pos) < 128) pos++;
            } else {
                throw fail("a digit");
            }
            if (pos < s.length() && s.charAt(pos) == '.') {
                pos++;
                int digits = pos;
                while (pos < s.length() && s.charAt(pos) >= '0' && s.charAt(pos) <= '9') pos++;
                if (pos == digits) throw fail("a digit");
            }
            if (pos < s.length() && (s.charAt(pos) == 'e' || s.charAt(pos) == 'E')) {
                pos++;
                if (pos < s.length() && (s.charAt(pos) == '+' || s.charAt(pos) == '-')) pos++;
                int digits = pos;
                while (pos < s.length() && s.charAt(pos) >= '0' && s.charAt(pos) <= '9') pos++;
                if (pos == digits) throw fail("a digit");
            }
            return new Num(s.substring(start, pos));
        }
    }
}

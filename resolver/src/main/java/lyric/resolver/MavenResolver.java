package lyric.resolver;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.eclipse.aether.RepositorySystem;
import org.eclipse.aether.RepositorySystemSession;
import org.eclipse.aether.artifact.DefaultArtifact;
import org.eclipse.aether.collection.CollectRequest;
import org.eclipse.aether.graph.Dependency;
import org.eclipse.aether.repository.LocalRepository;
import org.eclipse.aether.repository.RemoteRepository;
import org.eclipse.aether.resolution.ArtifactResult;
import org.eclipse.aether.resolution.DependencyRequest;
import org.eclipse.aether.resolution.DependencyResult;
import org.eclipse.aether.supplier.RepositorySystemSupplier;
import org.eclipse.aether.supplier.SessionBuilderSupplier;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.*;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.stream.Collectors;

/**
 * lyric-resolver: Maven Central dependency resolver for the Lyric compiler.
 *
 * <p>Reads a JSON resolution request from stdin:
 * <pre>{@code
 * {
 *   "coordinates": [{ "group": "...", "artifact": "...", "version": "..." }],
 *   "repositories": ["central"],
 *   "javaVersion": "21",
 *   "cacheDir": "/path/to/lyric/maven",
 *   "outputDir": "/path/to/target/restore/jars"
 * }
 * }</pre>
 *
 * <p>Writes a JSON array to stdout:
 * <pre>{@code
 * [{ "group": "...", "artifact": "...", "version": "...",
 *    "jarPath": "...", "sha256": "...", "isTopLevel": true,
 *    "classes": [{ "className": "...", "methods": [...] }] }]
 * }</pre>
 *
 * <p>See docs/31-maven-linking.md §3 for the full protocol spec (D052).
 */
public class MavenResolver {

    private static final String CENTRAL_URL = "https://repo1.maven.org/maven2/";
    private static final ObjectMapper JSON = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        String input = new String(System.in.readAllBytes(), StandardCharsets.UTF_8);
        JsonNode req = JSON.readTree(input);

        // Parse request.
        List<Coordinate> coordinates = new ArrayList<>();
        for (JsonNode c : req.get("coordinates")) {
            coordinates.add(new Coordinate(
                c.get("group").asText(),
                c.get("artifact").asText(),
                c.get("version").asText()
            ));
        }

        Set<String> topLevelKeys = coordinates.stream()
            .map(c -> c.group + ":" + c.artifact + ":" + c.version)
            .collect(Collectors.toSet());

        List<String> repos = new ArrayList<>();
        for (JsonNode r : req.get("repositories")) {
            repos.add(r.asText());
        }

        String javaVersion = req.path("javaVersion").asText("21");
        String cacheDir = req.get("cacheDir").asText();
        String outputDir = req.get("outputDir").asText();

        Files.createDirectories(Paths.get(cacheDir));
        Files.createDirectories(Paths.get(outputDir));

        // Build remote repository list.
        List<RemoteRepository> remoteRepos = new ArrayList<>();
        for (String repo : repos) {
            if ("central".equals(repo)) {
                remoteRepos.add(new RemoteRepository.Builder(
                    "central", "default", CENTRAL_URL).build());
            } else {
                String id = "extra-" + remoteRepos.size();
                remoteRepos.add(new RemoteRepository.Builder(id, "default", repo).build());
            }
        }
        if (remoteRepos.isEmpty()) {
            remoteRepos.add(new RemoteRepository.Builder(
                "central", "default", CENTRAL_URL).build());
        }

        // Set up Maven Resolver.
        RepositorySystem system = new RepositorySystemSupplier().get();
        RepositorySystemSession.SessionBuilder sessionBuilder =
            new SessionBuilderSupplier(system).get();
        sessionBuilder.withLocalRepositories(new LocalRepository(new File(cacheDir)));
        RepositorySystemSession session = sessionBuilder.build();

        // Collect and resolve the full dependency graph.
        CollectRequest collectRequest = new CollectRequest();
        for (Coordinate c : coordinates) {
            collectRequest.addDependency(
                new Dependency(
                    new DefaultArtifact(
                        c.group + ":" + c.artifact + ":" + c.version),
                    "compile"));
        }
        for (RemoteRepository r : remoteRepos) {
            collectRequest.addRepository(r);
        }

        DependencyRequest depRequest = new DependencyRequest(collectRequest, null);
        DependencyResult depResult = system.resolveDependencies(session, depRequest);

        // Collect results and copy JARs to outputDir.
        ArrayNode output = JSON.createArrayNode();

        for (ArtifactResult result : depResult.getArtifactResults()) {
            if (!result.isResolved()) continue;
            var artifact = result.getArtifact();
            if (artifact.getFile() == null) continue;

            String gav = artifact.getGroupId() + ":"
                + artifact.getArtifactId() + ":"
                + artifact.getVersion();
            boolean isTopLevel = topLevelKeys.contains(gav);

            // Copy JAR to outputDir.
            Path srcPath = artifact.getFile().toPath();
            String jarFileName = artifact.getArtifactId() + "-"
                + artifact.getVersion() + ".jar";
            Path destPath = Paths.get(outputDir, jarFileName);
            Files.copy(srcPath, destPath, StandardCopyOption.REPLACE_EXISTING);

            // Compute SHA-256 of the JAR.
            String sha256 = sha256Hex(destPath);

            ObjectNode entry = JSON.createObjectNode();
            entry.put("group", artifact.getGroupId());
            entry.put("artifact", artifact.getArtifactId());
            entry.put("version", artifact.getVersion());
            entry.put("jarPath", destPath.toAbsolutePath().toString());
            entry.put("sha256", sha256);
            entry.put("isTopLevel", isTopLevel);

            // Extract public class surface for top-level JARs.
            if (isTopLevel) {
                ArrayNode classes = extractClassSurface(destPath.toFile(), javaVersion);
                entry.set("classes", classes);
            } else {
                // Transitive deps: no class surface (shim generator skips them).
                entry.set("classes", JSON.createArrayNode());
            }

            output.add(entry);
        }

        System.out.println(JSON.writeValueAsString(output));
    }

    // -----------------------------------------------------------------------
    // SHA-256 helper.
    // -----------------------------------------------------------------------

    private static String sha256Hex(Path path) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        try (InputStream is = Files.newInputStream(path)) {
            byte[] buf = new byte[65536];
            int read;
            while ((read = is.read(buf)) != -1) {
                md.update(buf, 0, read);
            }
        }
        byte[] digest = md.digest();
        StringBuilder sb = new StringBuilder(digest.length * 2);
        for (byte b : digest) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }

    // -----------------------------------------------------------------------
    // Class surface extraction via ASM.
    // -----------------------------------------------------------------------

    /**
     * Walk the JAR, use ASM to read each {@code .class} file, and collect
     * public non-abstract top-level (non-inner) classes with their public
     * static methods.  Generic signatures are skipped (bootstrap-grade limit
     * matching NugetShim.fs).
     */
    private static ArrayNode extractClassSurface(File jar, String javaVersion) {
        ArrayNode classes = JSON.createArrayNode();
        try (JarFile jf = new JarFile(jar)) {
            Enumeration<JarEntry> entries = jf.entries();
            List<JarEntry> classEntries = new ArrayList<>();
            while (entries.hasMoreElements()) {
                JarEntry e = entries.nextElement();
                if (e.getName().endsWith(".class")
                        && !e.getName().contains("$")         // skip inner/anon
                        && !e.getName().equals("module-info.class")
                        && !e.getName().equals("package-info.class")) {
                    classEntries.add(e);
                }
            }
            // Sort for deterministic output.
            classEntries.sort(Comparator.comparing(JarEntry::getName));

            for (JarEntry entry : classEntries) {
                try (InputStream is = jf.getInputStream(entry)) {
                    byte[] bytes = is.readAllBytes();
                    ClassInfo ci = ClassScanner.scan(bytes);
                    if (ci == null) continue;  // non-public or interface
                    if (ci.methods.isEmpty()) continue;  // nothing translatable

                    ObjectNode clsNode = JSON.createObjectNode();
                    clsNode.put("className", ci.className);
                    ArrayNode methods = JSON.createArrayNode();
                    for (MethodInfo mi : ci.methods) {
                        ObjectNode mNode = JSON.createObjectNode();
                        mNode.put("name", mi.name);
                        mNode.put("returnType", mi.returnType);
                        mNode.put("isStatic", mi.isStatic);
                        mNode.put("hasCheckedExceptions", mi.hasCheckedExceptions);
                        ArrayNode params = JSON.createArrayNode();
                        for (ParamInfo pi : mi.params) {
                            ObjectNode pNode = JSON.createObjectNode();
                            pNode.put("name", pi.name);
                            pNode.put("typeName", pi.typeName);
                            params.add(pNode);
                        }
                        mNode.set("params", params);
                        methods.add(mNode);
                    }
                    clsNode.set("methods", methods);
                    classes.add(clsNode);
                } catch (Exception ex) {
                    // Skip malformed class files rather than aborting the whole
                    // JAR's surface extraction.
                }
            }
        } catch (IOException ex) {
            // If the JAR can't be opened, return an empty surface rather than
            // failing — the caller can shim with just the extern type block.
        }
        return classes;
    }

    // -----------------------------------------------------------------------
    // Data classes.
    // -----------------------------------------------------------------------

    static class Coordinate {
        final String group;
        final String artifact;
        final String version;

        Coordinate(String group, String artifact, String version) {
            this.group = group;
            this.artifact = artifact;
            this.version = version;
        }
    }

    static class ClassInfo {
        String className;
        List<MethodInfo> methods = new ArrayList<>();
    }

    static class MethodInfo {
        String name;
        String returnType;
        boolean isStatic;
        boolean hasCheckedExceptions;
        List<ParamInfo> params = new ArrayList<>();
    }

    static class ParamInfo {
        String name;
        String typeName;
    }
}

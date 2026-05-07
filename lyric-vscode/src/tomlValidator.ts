import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';

// ---------------------------------------------------------------------------
// Minimal line-aware TOML parser (sufficient for lyric.toml structure)
// ---------------------------------------------------------------------------

interface TomlEntry {
    key: string;
    value: string;
    line: number;       // 0-based
    keyStart: number;   // column
    keyEnd: number;
    valueStart: number;
    valueEnd: number;
    rawValue: string;   // verbatim from source
}

interface TomlSection {
    name: string;
    headerLine: number;
    entries: TomlEntry[];
}

interface ParsedToml {
    sections: TomlSection[];
    // Entries before any section header belong to the root section "".
}

function parseToml(text: string): ParsedToml {
    const lines = text.split('\n');
    const sections: TomlSection[] = [];
    let current: TomlSection = { name: '', headerLine: -1, entries: [] };
    sections.push(current);

    for (let i = 0; i < lines.length; i++) {
        const raw = lines[i];
        const line = raw.replace(/#.*$/, '').trimEnd(); // strip comments

        // Section header: [name] or [name.sub]
        const sectionMatch = /^\s*\[([^\[\]]+)\]\s*$/.exec(line);
        if (sectionMatch) {
            current = { name: sectionMatch[1].trim(), headerLine: i, entries: [] };
            sections.push(current);
            continue;
        }

        // Key = value (bare key or quoted key)
        const kvMatch = /^\s*("([^"]+)"|([A-Za-z0-9_.:-]+))\s*=\s*(.*)$/.exec(line);
        if (!kvMatch) continue;

        const fullKey = kvMatch[2] ?? kvMatch[3];
        const rawVal = kvMatch[4].trim();
        const keyStart = raw.indexOf(kvMatch[1]);
        const keyEnd = keyStart + kvMatch[1].length;
        const valueStart = raw.indexOf('=') + 1 + (raw.slice(raw.indexOf('=') + 1).search(/\S/));
        const valueEnd = raw.trimEnd().length;

        // Unquote simple string values for semantic checks
        const stringMatch = /^"((?:[^"\\]|\\.)*)"/.exec(rawVal);
        const boolMatch = /^(true|false)$/.exec(rawVal);
        const value = stringMatch ? stringMatch[1] : (boolMatch ? boolMatch[1] : rawVal);

        current.entries.push({ key: fullKey, value, rawValue: rawVal, line: i, keyStart, keyEnd, valueStart, valueEnd });
    }

    return { sections };
}

// ---------------------------------------------------------------------------
// Semantic validation rules
// ---------------------------------------------------------------------------

const KNOWN_SECTIONS = new Set([
    '', 'project', 'project.packages', 'dependencies', 'nuget', 'nuget.options',
]);

const OUTPUT_VALUES = new Set(['single', 'multi']);

const SEMVER_RE = /^\d+\.\d+(\.\d+)?([-+].+)?$/;

// Loose NuGet ID: letters/digits/dots/hyphens, non-empty
const NUGET_ID_RE = /^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$/;

function sectionByName(parsed: ParsedToml, name: string): TomlSection | undefined {
    return parsed.sections.find(s => s.name === name);
}

function entryByKey(section: TomlSection | undefined, key: string): TomlEntry | undefined {
    return section?.entries.find(e => e.key === key);
}

function entryRange(doc: vscode.TextDocument, entry: TomlEntry): vscode.Range {
    return new vscode.Range(
        new vscode.Position(entry.line, entry.keyStart),
        new vscode.Position(entry.line, entry.valueEnd),
    );
}

function keyRange(doc: vscode.TextDocument, entry: TomlEntry): vscode.Range {
    return new vscode.Range(
        new vscode.Position(entry.line, entry.keyStart),
        new vscode.Position(entry.line, entry.keyEnd),
    );
}

function valueRange(doc: vscode.TextDocument, entry: TomlEntry): vscode.Range {
    return new vscode.Range(
        new vscode.Position(entry.line, entry.valueStart),
        new vscode.Position(entry.line, entry.valueEnd),
    );
}

function headerRange(doc: vscode.TextDocument, section: TomlSection): vscode.Range {
    const line = doc.lineAt(section.headerLine);
    return line.range;
}

export function validateManifest(
    doc: vscode.TextDocument,
    manifestDir: string,
): vscode.Diagnostic[] {
    const diags: vscode.Diagnostic[] = [];
    const text = doc.getText();
    const parsed = parseToml(text);

    function error(range: vscode.Range, msg: string): void {
        diags.push(new vscode.Diagnostic(range, msg, vscode.DiagnosticSeverity.Error));
    }
    function warn(range: vscode.Range, msg: string): void {
        diags.push(new vscode.Diagnostic(range, msg, vscode.DiagnosticSeverity.Warning));
    }
    function hint(range: vscode.Range, msg: string): void {
        diags.push(new vscode.Diagnostic(range, msg, vscode.DiagnosticSeverity.Hint));
    }

    // ── 1. Unknown top-level sections ──────────────────────────────────────
    for (const s of parsed.sections) {
        if (s.name === '') continue; // root
        if (!KNOWN_SECTIONS.has(s.name)) {
            const range = new vscode.Range(s.headerLine, 0, s.headerLine, doc.lineAt(s.headerLine).text.length);
            // Suggest likely typos
            const suggestions = Array.from(KNOWN_SECTIONS)
                .filter(k => k && levenshtein(s.name, k) <= 3)
                .map(k => `[${k}]`);
            const hint2 = suggestions.length > 0 ? ` Did you mean ${suggestions.join(' or ')}?` : '';
            warn(range, `Unknown section "[${s.name}]".${hint2}`);
        }
    }

    // ── 2. [project] checks ────────────────────────────────────────────────
    const project = sectionByName(parsed, 'project');

    if (!project) {
        const firstLine = new vscode.Range(0, 0, 0, 0);
        error(firstLine, 'lyric.toml: missing required [project] section.');
    } else {
        // 2a. name is required
        const nameEntry = entryByKey(project, 'name');
        if (!nameEntry) {
            const range = new vscode.Range(project.headerLine, 0, project.headerLine, doc.lineAt(project.headerLine).text.length);
            error(range, '[project] is missing required key "name".');
        } else if (!nameEntry.value.trim()) {
            error(valueRange(doc, nameEntry), '"name" must not be empty.');
        }

        // 2b. output must be "single" or "multi"
        const outputEntry = entryByKey(project, 'output');
        if (outputEntry && !OUTPUT_VALUES.has(outputEntry.value)) {
            error(
                valueRange(doc, outputEntry),
                `"output" must be "single" or "multi", got "${outputEntry.value}".`,
            );
        }

        // 2c. output_assembly should end in .dll
        const asmEntry = entryByKey(project, 'output_assembly');
        if (asmEntry && !asmEntry.value.endsWith('.dll')) {
            warn(
                valueRange(doc, asmEntry),
                '"output_assembly" should end with ".dll".',
            );
        }

        // 2d. version should be semver
        const verEntry = entryByKey(project, 'version');
        if (verEntry && !SEMVER_RE.test(verEntry.value)) {
            warn(
                valueRange(doc, verEntry),
                `"version" should be a SemVer string (e.g. "1.0.0"), got "${verEntry.value}".`,
            );
        }

        // 2e. Unknown keys in [project]
        const knownProjectKeys = new Set(['name', 'output', 'output_assembly', 'entry', 'version', 'authors', 'description', 'license']);
        for (const e of project.entries) {
            if (!knownProjectKeys.has(e.key)) {
                warn(keyRange(doc, e), `Unknown key "${e.key}" in [project].`);
            }
        }
    }

    // ── 3. [project.packages] cross-reference ─────────────────────────────
    const packages = sectionByName(parsed, 'project.packages');
    const packageNames = new Set(packages?.entries.map(e => e.key) ?? []);

    // entry must refer to a known package
    if (project) {
        const entryEntry = entryByKey(project, 'entry');
        if (entryEntry && !packageNames.has(entryEntry.value)) {
            error(
                valueRange(doc, entryEntry),
                `"entry" refers to package "${entryEntry.value}" which is not declared in [project.packages].`,
            );
        }
    }

    // package source directories must exist
    if (packages) {
        for (const e of packages.entries) {
            if (!e.value) {
                error(valueRange(doc, e), `Source directory for package "${e.key}" must not be empty.`);
                continue;
            }
            const absDir = path.resolve(manifestDir, e.value);
            if (!fs.existsSync(absDir)) {
                warn(
                    valueRange(doc, e),
                    `Source directory "${e.value}" does not exist (expected at ${absDir}).`,
                );
            }
        }
        checkDuplicateKeys(doc, packages, warn);
    }

    // ── 4. [dependencies] version checks ──────────────────────────────────
    const deps = sectionByName(parsed, 'dependencies');
    if (deps) {
        for (const e of deps.entries) {
            if (!e.value.trim()) {
                error(valueRange(doc, e), `Version for dependency "${e.key}" must not be empty.`);
            } else if (!SEMVER_RE.test(e.value.trim())) {
                warn(
                    valueRange(doc, e),
                    `Version "${e.value}" for dependency "${e.key}" does not look like SemVer.`,
                );
            }
        }
        checkDuplicateKeys(doc, deps, warn);
    }

    // ── 5. [nuget] package ID and version checks ───────────────────────────
    const nuget = sectionByName(parsed, 'nuget');
    if (nuget) {
        for (const e of nuget.entries) {
            if (!NUGET_ID_RE.test(e.key)) {
                warn(keyRange(doc, e), `"${e.key}" does not look like a valid NuGet package ID.`);
            }
            if (!e.value.trim()) {
                error(valueRange(doc, e), `Version for NuGet package "${e.key}" must not be empty.`);
            }
        }
        checkDuplicateKeys(doc, nuget, warn);
    }

    // ── 6. [nuget.options] known-key check ────────────────────────────────
    const nugetOpts = sectionByName(parsed, 'nuget.options');
    if (nugetOpts) {
        const knownNugetOpts = new Set(['source', 'target_framework', 'no_cache']);
        for (const e of nugetOpts.entries) {
            if (!knownNugetOpts.has(e.key)) {
                warn(keyRange(doc, e), `Unknown key "${e.key}" in [nuget.options].`);
            }
        }
    }

    return diags;
}

function checkDuplicateKeys(
    doc: vscode.TextDocument,
    section: TomlSection,
    warn: (r: vscode.Range, m: string) => void,
): void {
    const seen = new Map<string, number>();
    for (const e of section.entries) {
        if (seen.has(e.key)) {
            warn(
                keyRange(doc, e),
                `Duplicate key "${e.key}" in [${section.name}] (first defined on line ${(seen.get(e.key)! + 1)}).`,
            );
        } else {
            seen.set(e.key, e.line);
        }
    }
}

// ---------------------------------------------------------------------------
// Simple Levenshtein for typo suggestions (small strings only)
// ---------------------------------------------------------------------------

function levenshtein(a: string, b: string): number {
    const m = a.length, n = b.length;
    const dp: number[][] = Array.from({ length: m + 1 }, (_, i) =>
        Array.from({ length: n + 1 }, (_, j) => (i === 0 ? j : j === 0 ? i : 0))
    );
    for (let i = 1; i <= m; i++) {
        for (let j = 1; j <= n; j++) {
            dp[i][j] = a[i - 1] === b[j - 1]
                ? dp[i - 1][j - 1]
                : 1 + Math.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]);
        }
    }
    return dp[m][n];
}

// ---------------------------------------------------------------------------
// VS Code integration: diagnostics collection + document watcher
// ---------------------------------------------------------------------------

let diagnostics: vscode.DiagnosticCollection | undefined;

export function registerTomlValidator(context: vscode.ExtensionContext): void {
    diagnostics = vscode.languages.createDiagnosticCollection('lyric-manifest');
    context.subscriptions.push(diagnostics);

    const validate = (doc: vscode.TextDocument) => {
        if (!doc.fileName.endsWith('lyric.toml')) return;
        const manifestDir = path.dirname(doc.uri.fsPath);
        const diags = validateManifest(doc, manifestDir);
        diagnostics!.set(doc.uri, diags);
    };

    // Validate open documents immediately
    for (const doc of vscode.workspace.textDocuments) {
        validate(doc);
    }

    context.subscriptions.push(
        vscode.workspace.onDidOpenTextDocument(validate),
        vscode.workspace.onDidChangeTextDocument(e => validate(e.document)),
        vscode.workspace.onDidCloseTextDocument(doc => diagnostics!.delete(doc.uri)),
    );
}

import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';

export interface LyricManifest {
    projectName: string;
    output: string;
    packages: Record<string, string>;
    dependencies: Record<string, string>;
    nuget: Record<string, string>;
}

export function findManifest(workspaceRoot: string): string | undefined {
    const candidate = path.join(workspaceRoot, 'lyric.toml');
    return fs.existsSync(candidate) ? candidate : undefined;
}

export function findManifestInWorkspace(): string | undefined {
    for (const folder of vscode.workspace.workspaceFolders ?? []) {
        const m = findManifest(folder.uri.fsPath);
        if (m) return m;
    }
    return undefined;
}

export function parseManifest(tomlPath: string): LyricManifest {
    const text = fs.existsSync(tomlPath) ? fs.readFileSync(tomlPath, 'utf8') : '';
    return {
        projectName: extractScalar(text, 'project', 'name') ?? path.basename(path.dirname(tomlPath)),
        output: extractScalar(text, 'project', 'output') ?? 'single',
        packages: extractTable(text, 'project.packages'),
        dependencies: extractTable(text, 'dependencies'),
        nuget: extractTable(text, 'nuget'),
    };
}

// Minimal TOML section extraction — sufficient for the simple lyric.toml structure.
// Does not handle multi-line values or arrays of tables.

function extractScalar(text: string, section: string, key: string): string | undefined {
    const sectionPattern = new RegExp(`^\\[${escapeRegex(section)}\\]`, 'm');
    const sectionMatch = sectionPattern.exec(text);
    if (!sectionMatch) return undefined;
    const after = text.slice(sectionMatch.index + sectionMatch[0].length);
    const nextSection = /^\[/m.exec(after);
    const block = nextSection ? after.slice(0, nextSection.index) : after;
    const kv = new RegExp(`^\\s*${escapeRegex(key)}\\s*=\\s*"([^"]*)"`, 'm').exec(block);
    return kv?.[1];
}

function extractTable(text: string, section: string): Record<string, string> {
    const result: Record<string, string> = {};
    const sectionPattern = new RegExp(`^\\[${escapeRegex(section)}\\]`, 'm');
    const sectionMatch = sectionPattern.exec(text);
    if (!sectionMatch) return result;
    const after = text.slice(sectionMatch.index + sectionMatch[0].length);
    const nextSection = /^\[/m.exec(after);
    const block = nextSection ? after.slice(0, nextSection.index) : after;
    const lineRe = /^\s*"([^"]+)"\s*=\s*"([^"]*)"/gm;
    let m: RegExpExecArray | null;
    while ((m = lineRe.exec(block)) !== null) {
        result[m[1]] = m[2];
    }
    const bareLineRe = /^\s*([A-Za-z0-9_.:-]+)\s*=\s*"([^"]*)"/gm;
    while ((m = bareLineRe.exec(block)) !== null) {
        if (!(m[1] in result)) {
            result[m[1]] = m[2];
        }
    }
    return result;
}

function escapeRegex(s: string): string {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function addEntryToSection(tomlPath: string, section: string, key: string, value: string): void {
    let text = fs.existsSync(tomlPath) ? fs.readFileSync(tomlPath, 'utf8') : '';
    const sectionHeader = `[${section}]`;
    const sectionPattern = new RegExp(`^\\[${escapeRegex(section)}\\]`, 'm');
    const newLine = `"${key}" = "${value}"\n`;

    if (sectionPattern.test(text)) {
        // Append after the section header's last existing entry before the next section
        const sectionMatch = sectionPattern.exec(text)!;
        const after = text.slice(sectionMatch.index + sectionMatch[0].length);
        const nextSection = /^\[/m.exec(after);
        const insertOffset = nextSection
            ? sectionMatch.index + sectionMatch[0].length + nextSection.index
            : text.length;
        // Insert before next section (or at end), with trailing newline
        const insertAt = nextSection
            ? sectionMatch.index + sectionMatch[0].length + nextSection.index
            : text.length;
        text = text.slice(0, insertAt) + newLine + text.slice(insertAt);
    } else {
        // Append new section at end of file
        if (text.length > 0 && !text.endsWith('\n')) text += '\n';
        text += `\n${sectionHeader}\n${newLine}`;
    }

    fs.writeFileSync(tomlPath, text, 'utf8');
}

export function removeEntryFromSection(tomlPath: string, section: string, key: string): boolean {
    if (!fs.existsSync(tomlPath)) return false;
    let text = fs.readFileSync(tomlPath, 'utf8');
    const sectionPattern = new RegExp(`^\\[${escapeRegex(section)}\\]`, 'm');
    const sectionMatch = sectionPattern.exec(text);
    if (!sectionMatch) return false;

    const afterStart = sectionMatch.index + sectionMatch[0].length;
    const after = text.slice(afterStart);
    const nextSection = /^\[/m.exec(after);
    const blockEnd = nextSection ? afterStart + nextSection.index : text.length;

    // Remove lines matching the key (quoted or bare)
    const quotedRe = new RegExp(`^[ \\t]*"${escapeRegex(key)}"\\s*=.*\\n?`, 'm');
    const bareRe = new RegExp(`^[ \\t]*${escapeRegex(key)}\\s*=.*\\n?`, 'm');

    const block = text.slice(afterStart, blockEnd);
    let newBlock = block.replace(quotedRe, '').replace(bareRe, '');
    if (newBlock === block) return false;

    text = text.slice(0, afterStart) + newBlock + text.slice(blockEnd);
    fs.writeFileSync(tomlPath, text, 'utf8');
    return true;
}

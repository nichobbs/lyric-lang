import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import { findManifestInWorkspace, parseManifest } from './tomlEditor';

type NodeKind = 'group' | 'package' | 'dependency' | 'nuget';

export class LyricProjectNode extends vscode.TreeItem {
    constructor(
        readonly label: string,
        readonly kind: NodeKind,
        readonly detail: string,
        readonly collapsible: vscode.TreeItemCollapsibleState,
    ) {
        super(label, collapsible);
        this.description = detail;
        this.contextValue = kind;
        this.iconPath = iconFor(kind);
        if (kind === 'package' && detail) {
            this.resourceUri = vscode.Uri.file(detail);
            this.command = {
                command: 'vscode.openFolder',
                title: 'Open package directory',
                arguments: [this.resourceUri],
            };
        }
    }
}

function iconFor(kind: NodeKind): vscode.ThemeIcon {
    switch (kind) {
        case 'group':      return new vscode.ThemeIcon('folder');
        case 'package':    return new vscode.ThemeIcon('package');
        case 'dependency': return new vscode.ThemeIcon('library');
        case 'nuget':      return new vscode.ThemeIcon('cloud-download');
    }
}

export class LyricProjectProvider implements vscode.TreeDataProvider<LyricProjectNode> {
    private readonly _onDidChangeTreeData = new vscode.EventEmitter<LyricProjectNode | undefined | void>();
    readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

    refresh(): void {
        this._onDidChangeTreeData.fire();
    }

    getTreeItem(element: LyricProjectNode): vscode.TreeItem {
        return element;
    }

    getChildren(element?: LyricProjectNode): LyricProjectNode[] {
        if (!element) {
            return this.roots();
        }
        if (element.kind === 'group') {
            return this.childrenForGroup(element.label);
        }
        return [];
    }

    private manifest() {
        const p = findManifestInWorkspace();
        return p ? parseManifest(p) : null;
    }

    private roots(): LyricProjectNode[] {
        const m = this.manifest();
        if (!m) return [];
        const nodes: LyricProjectNode[] = [];
        if (Object.keys(m.packages).length > 0) {
            nodes.push(new LyricProjectNode(
                'Packages', 'group', `${Object.keys(m.packages).length} package(s)`,
                vscode.TreeItemCollapsibleState.Expanded,
            ));
        }
        if (Object.keys(m.dependencies).length > 0) {
            nodes.push(new LyricProjectNode(
                'Lyric dependencies', 'group', `${Object.keys(m.dependencies).length} package(s)`,
                vscode.TreeItemCollapsibleState.Collapsed,
            ));
        }
        if (Object.keys(m.nuget).length > 0) {
            nodes.push(new LyricProjectNode(
                'NuGet dependencies', 'group', `${Object.keys(m.nuget).length} package(s)`,
                vscode.TreeItemCollapsibleState.Collapsed,
            ));
        }
        return nodes;
    }

    private childrenForGroup(groupLabel: string): LyricProjectNode[] {
        const m = this.manifest();
        if (!m) return [];
        if (groupLabel === 'Packages') {
            return Object.entries(m.packages).map(([name, srcDir]) => {
                const absDir = this.resolvePackageDir(srcDir);
                return new LyricProjectNode(
                    name, 'package', srcDir,
                    vscode.TreeItemCollapsibleState.None,
                );
            });
        }
        if (groupLabel === 'Lyric dependencies') {
            return Object.entries(m.dependencies).map(([name, version]) =>
                new LyricProjectNode(name, 'dependency', version, vscode.TreeItemCollapsibleState.None),
            );
        }
        if (groupLabel === 'NuGet dependencies') {
            return Object.entries(m.nuget).map(([name, version]) =>
                new LyricProjectNode(name, 'nuget', version, vscode.TreeItemCollapsibleState.None),
            );
        }
        return [];
    }

    private resolvePackageDir(srcDir: string): string | undefined {
        for (const folder of vscode.workspace.workspaceFolders ?? []) {
            const abs = path.resolve(folder.uri.fsPath, srcDir);
            if (fs.existsSync(abs)) return abs;
        }
        return undefined;
    }
}

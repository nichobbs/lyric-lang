import * as cp from 'child_process';
import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
} from 'vscode-languageclient/node';
import {
    addEntryToSection,
    findManifestInWorkspace,
    parseManifest,
    removeEntryFromSection,
} from './tomlEditor';
import { LyricProjectProvider } from './projectNavigator';
import { LyricTaskProvider, runLyricInTerminal, runLyricRestore } from './taskProvider';
import { createFormatter } from './formatter';
import { registerTomlValidator } from './tomlValidator';

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    startLsp(context);
    registerNavigator(context);
    registerCommands(context);
    registerTasks(context);
    registerFormatter(context);
    registerTomlValidator(context);
    setManifestContext();
    watchManifest(context);
}

export function deactivate(): Thenable<void> | undefined {
    return client?.stop();
}

// LSP -------------------------------------------------------------------------

function startLsp(context: vscode.ExtensionContext): void {
    const config = vscode.workspace.getConfiguration('lyric');
    const serverPath = config.get<string>('serverPath', 'lyric');

    const serverOptions: ServerOptions = {
        command: serverPath,
        args: ['lsp'],
        transport: TransportKind.stdio,
        options: { env: process.env },
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'lyric' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.l'),
        },
        traceOutputChannel: vscode.window.createOutputChannel('Lyric Language Server Trace'),
    };

    client = new LanguageClient('lyric', 'Lyric Language Server', serverOptions, clientOptions);

    client.start().catch(async (err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        const isNotFound = (typeof err === 'object' && err !== null && 'code' in err && (err as { code: unknown }).code === 'ENOENT') || msg.includes('ENOENT');
        
        let choice: string | undefined;
        if (isNotFound) {
            choice = await vscode.window.showErrorMessage(
                `Lyric Language Server could not be found at "${serverPath}". ` +
                `Would you like to install the Lyric CLI global tool via dotnet, or view the manual setup guide?`,
                'Install via dotnet',
                'View Setup Guide'
            );
        } else {
            choice = await vscode.window.showErrorMessage(
                `Lyric: failed to start language server (${serverPath}): ${msg}. ` +
                `Set "lyric.serverPath" to the lyric binary (the LSP server runs via "lyric lsp").`,
                'View Setup Guide'
            );
        }

        if (choice === 'Install via dotnet') {
            cp.exec('dotnet --version', (error) => {
                void (async () => {
                    if (error) {
                        // `error` is set for any exec failure (ENOENT, EACCES, EPERM,
                        // a non-zero exit, a timeout, ...), not just "binary missing".
                        // Only report the .NET-SDK-missing message for the case it
                        // actually describes; anything else would send a user with a
                        // working but misbehaving `dotnet` on a wild goose chase.
                        const isNotFound = (error as NodeJS.ErrnoException).code === 'ENOENT';
                        const message = isNotFound
                            ? 'The .NET SDK is required to install the Lyric CLI, but "dotnet" was not found on your PATH. ' +
                              'Please install the .NET SDK and try again.'
                            : `"dotnet --version" failed: ${error.message}. Please resolve this and try again.`;
                        const guideChoice = await vscode.window.showErrorMessage(message, 'View Setup Guide');
                        if (guideChoice === 'View Setup Guide') {
                            vscode.env.openExternal(vscode.Uri.parse('https://github.com/nichobbs/lyric-lang#quick-start'));
                        }
                        return;
                    }

                    const terminal = vscode.window.createTerminal('Lyric Installation');
                    terminal.show();
                    terminal.sendText('dotnet tool install -g lyric');

                    // VS Code exposes no reliable terminal process-exit event for a
                    // command sent via `sendText`, so there is no safe way to know
                    // when the install actually finishes. Rather than offer a
                    // "Reload Window" button that races the install (clicking it
                    // before `dotnet tool install` completes reloads into the same
                    // broken state), just point the user at reloading manually once
                    // the terminal confirms success.
                    await vscode.window.showInformationMessage(
                        'Running "dotnet tool install -g lyric" in the integrated terminal. ' +
                        'Once the terminal shows the installation succeeded, reload the window ' +
                        '(Command Palette -> "Developer: Reload Window") to activate the language server.'
                    );
                })().catch(err => {
                    console.error('Error in install flow:', err);
                });
            });
        } else if (choice === 'View Setup Guide') {
            vscode.env.openExternal(vscode.Uri.parse('https://github.com/nichobbs/lyric-lang#quick-start'));
        }
    });

    context.subscriptions.push(client);
}

// Project navigator -----------------------------------------------------------

let navigator: LyricProjectProvider | undefined;

function registerNavigator(context: vscode.ExtensionContext): void {
    navigator = new LyricProjectProvider();
    context.subscriptions.push(
        vscode.window.registerTreeDataProvider('lyricProjectNavigator', navigator),
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('lyric.refreshNavigator', () => navigator?.refresh()),
    );
}

// Task provider ---------------------------------------------------------------

function registerTasks(context: vscode.ExtensionContext): void {
    context.subscriptions.push(
        vscode.tasks.registerTaskProvider(LyricTaskProvider.taskType, new LyricTaskProvider()),
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('lyric.build', () => runTask('build')),
        vscode.commands.registerCommand('lyric.run', () => runTask('run')),
        vscode.commands.registerCommand('lyric.test', () => runTask('test')),
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('lyric.proveCurrentFile', () => proveCurrentFile()),
    );
}

async function runTask(command: string): Promise<void> {
    const folder = vscode.workspace.workspaceFolders?.[0];
    if (!folder) {
        vscode.window.showErrorMessage('Lyric: no workspace folder open.');
        return;
    }
    const manifest = findManifestInWorkspace() ?? path.join(folder.uri.fsPath, 'lyric.toml');
    await vscode.tasks.executeTask(
        new vscode.Task(
            { type: 'lyric', command },
            folder,
            command,
            'lyric',
            new vscode.ShellExecution(
                vscode.workspace.getConfiguration('lyric').get<string>('cliPath', 'lyric'),
                [command, '--manifest', manifest],
                { cwd: folder.uri.fsPath },
            ),
        ),
    );
}

async function proveCurrentFile(): Promise<void> {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'lyric') {
        vscode.window.showWarningMessage('Lyric: open a .l file to prove it.');
        return;
    }
    const filePath = editor.document.uri.fsPath;
    await runLyricInTerminal(['prove', filePath], 'Lyric: Prove');
}

// Package management commands -------------------------------------------------

function registerCommands(context: vscode.ExtensionContext): void {
    context.subscriptions.push(
        vscode.commands.registerCommand('lyric.restore', cmdRestore),
        vscode.commands.registerCommand('lyric.addDependency', cmdAddDependency),
        vscode.commands.registerCommand('lyric.addNugetPackage', cmdAddNuget),
        vscode.commands.registerCommand('lyric.removeDependency', cmdRemoveDependency),
        vscode.commands.registerCommand('lyric.updateDependency', cmdUpdateDependency),
    );
}

async function cmdRestore(): Promise<void> {
    await runLyricRestore();
    navigator?.refresh();
}

async function cmdAddDependency(): Promise<void> {
    const manifest = findManifestInWorkspace();
    if (!manifest) { showNoManifest(); return; }

    const pkg = await vscode.window.showInputBox({
        prompt: 'Lyric package identifier (e.g. Acme.Utils)',
        validateInput: v => v.trim() ? undefined : 'Package name required',
    });
    if (!pkg) return;

    const version = await vscode.window.showInputBox({
        prompt: `Version constraint for "${pkg}" (e.g. 1.0.0)`,
        value: '1.0.0',
        validateInput: v => v.trim() ? undefined : 'Version required',
    });
    if (!version) return;

    addEntryToSection(manifest, 'dependencies', pkg.trim(), version.trim());
    await vscode.workspace.openTextDocument(vscode.Uri.file(manifest));
    navigator?.refresh();
    const restore = await vscode.window.showInformationMessage(
        `Added "${pkg}" to dependencies. Run restore?`,
        'Restore', 'Later',
    );
    if (restore === 'Restore') await runLyricRestore(manifest);
}

async function cmdAddNuget(): Promise<void> {
    const manifest = findManifestInWorkspace();
    if (!manifest) { showNoManifest(); return; }

    const pkg = await vscode.window.showInputBox({
        prompt: 'NuGet package ID (e.g. Newtonsoft.Json)',
        validateInput: v => v.trim() ? undefined : 'Package ID required',
    });
    if (!pkg) return;

    const version = await vscode.window.showInputBox({
        prompt: `Version for "${pkg}" (e.g. 13.0.3)`,
        value: '1.0.0',
        validateInput: v => v.trim() ? undefined : 'Version required',
    });
    if (!version) return;

    addEntryToSection(manifest, 'nuget', pkg.trim(), version.trim());
    navigator?.refresh();
    const restore = await vscode.window.showInformationMessage(
        `Added NuGet package "${pkg}". Run restore?`,
        'Restore', 'Later',
    );
    if (restore === 'Restore') await runLyricRestore(manifest);
}

async function cmdRemoveDependency(): Promise<void> {
    const manifest = findManifestInWorkspace();
    if (!manifest) { showNoManifest(); return; }

    const m = parseManifest(manifest);
    const allEntries: vscode.QuickPickItem[] = [
        ...Object.entries(m.dependencies).map(([k, v]) => ({ label: k, description: `Lyric  ${v}` })),
        ...Object.entries(m.nuget).map(([k, v]) => ({ label: k, description: `NuGet  ${v}` })),
    ];
    if (allEntries.length === 0) {
        vscode.window.showInformationMessage('No dependencies in lyric.toml.');
        return;
    }

    const picked = await vscode.window.showQuickPick(allEntries, {
        placeHolder: 'Select dependency to remove',
    });
    if (!picked) return;

    const isNuget = picked.description?.startsWith('NuGet');
    const section = isNuget ? 'nuget' : 'dependencies';
    const removed = removeEntryFromSection(manifest, section, picked.label);
    if (removed) {
        vscode.window.showInformationMessage(`Removed "${picked.label}" from lyric.toml.`);
        navigator?.refresh();
    } else {
        vscode.window.showWarningMessage(`Could not remove "${picked.label}" — check lyric.toml manually.`);
    }
}

async function cmdUpdateDependency(): Promise<void> {
    const manifest = findManifestInWorkspace();
    if (!manifest) { showNoManifest(); return; }

    const m = parseManifest(manifest);
    const allEntries: vscode.QuickPickItem[] = [
        ...Object.entries(m.dependencies).map(([k, v]) => ({ label: k, description: `Lyric  ${v}` })),
        ...Object.entries(m.nuget).map(([k, v]) => ({ label: k, description: `NuGet  ${v}` })),
    ];
    if (allEntries.length === 0) {
        vscode.window.showInformationMessage('No dependencies in lyric.toml.');
        return;
    }

    const picked = await vscode.window.showQuickPick(allEntries, {
        placeHolder: 'Select dependency to update',
    });
    if (!picked) return;

    const currentVersion = picked.description?.split(/\s+/).pop() ?? '';
    const newVersion = await vscode.window.showInputBox({
        prompt: `New version for "${picked.label}"`,
        value: currentVersion,
        validateInput: v => v.trim() ? undefined : 'Version required',
    });
    if (!newVersion || newVersion.trim() === currentVersion) return;

    const isNuget = picked.description?.startsWith('NuGet');
    const section = isNuget ? 'nuget' : 'dependencies';

    removeEntryFromSection(manifest, section, picked.label);
    addEntryToSection(manifest, section, picked.label, newVersion.trim());
    navigator?.refresh();

    const restore = await vscode.window.showInformationMessage(
        `Updated "${picked.label}" to ${newVersion.trim()}. Run restore?`,
        'Restore', 'Later',
    );
    if (restore === 'Restore') await runLyricRestore(manifest);
}

// Formatter -------------------------------------------------------------------

function registerFormatter(context: vscode.ExtensionContext): void {
    context.subscriptions.push(
        vscode.languages.registerDocumentFormattingEditProvider(
            { language: 'lyric', scheme: 'file' },
            createFormatter(context),
        ),
    );
}

// Utilities -------------------------------------------------------------------

function showNoManifest(): void {
    vscode.window.showErrorMessage(
        'Lyric: no lyric.toml found in the workspace root. Create one to manage dependencies.',
    );
}

function setManifestContext(): void {
    const has = !!findManifestInWorkspace();
    vscode.commands.executeCommand('setContext', 'lyric.hasManifest', has);
}

function watchManifest(context: vscode.ExtensionContext): void {
    const watcher = vscode.workspace.createFileSystemWatcher('**/lyric.toml');
    const refresh = () => {
        setManifestContext();
        navigator?.refresh();
    };
    context.subscriptions.push(
        watcher,
        watcher.onDidCreate(refresh),
        watcher.onDidChange(refresh),
        watcher.onDidDelete(refresh),
    );
}

import * as path from 'path';
import * as vscode from 'vscode';
import { findManifestInWorkspace } from './tomlEditor';

interface LyricTaskDefinition extends vscode.TaskDefinition {
    type: 'lyric';
    command: 'build' | 'run' | 'test' | 'prove' | 'restore';
    args?: string[];
    manifestPath?: string;
}

const TASK_SOURCE = 'lyric';

function lyricCli(): string {
    return vscode.workspace.getConfiguration('lyric').get<string>('cliPath', 'lyric');
}

function buildTask(def: LyricTaskDefinition, workspaceFolder: vscode.WorkspaceFolder): vscode.Task {
    const cli = lyricCli();
    const extraArgs = def.args ?? [];
    let cmdArgs: string[];

    switch (def.command) {
        case 'build': {
            const manifest = def.manifestPath ?? 'lyric.toml';
            cmdArgs = ['build', '--manifest', manifest, ...extraArgs];
            break;
        }
        case 'run': {
            const manifest = def.manifestPath ?? 'lyric.toml';
            cmdArgs = ['run', '--manifest', manifest, ...extraArgs];
            break;
        }
        case 'test': {
            const manifest = def.manifestPath ?? 'lyric.toml';
            cmdArgs = ['test', '--manifest', manifest, ...extraArgs];
            break;
        }
        case 'prove': {
            cmdArgs = ['prove', ...extraArgs];
            break;
        }
        case 'restore': {
            const manifest = def.manifestPath ?? 'lyric.toml';
            cmdArgs = ['restore', '--manifest', manifest, ...extraArgs];
            break;
        }
    }

    const task = new vscode.Task(
        def,
        workspaceFolder,
        taskLabel(def),
        TASK_SOURCE,
        new vscode.ShellExecution(cli, cmdArgs, {
            cwd: workspaceFolder.uri.fsPath,
        }),
        '$lyric',
    );
    task.group = taskGroup(def.command);
    task.presentationOptions = {
        reveal: vscode.TaskRevealKind.Always,
        panel: vscode.TaskPanelKind.Shared,
        clear: true,
    };
    return task;
}

function taskLabel(def: LyricTaskDefinition): string {
    switch (def.command) {
        case 'build':   return 'Build current project';
        case 'run':     return 'Run';
        case 'test':    return 'Test';
        case 'prove':   return 'Prove current file';
        case 'restore': return 'Restore';
    }
}

function taskGroup(command: LyricTaskDefinition['command']): vscode.TaskGroup | undefined {
    switch (command) {
        case 'build':   return vscode.TaskGroup.Build;
        case 'test':    return vscode.TaskGroup.Test;
        default:        return undefined;
    }
}

export class LyricTaskProvider implements vscode.TaskProvider {
    static readonly taskType = 'lyric';

    provideTasks(): vscode.Task[] {
        const folders = vscode.workspace.workspaceFolders;
        if (!folders || folders.length === 0) return [];
        const folder = folders[0];

        const commands: LyricTaskDefinition['command'][] = ['build', 'run', 'test', 'restore'];
        return commands.map(cmd => buildTask({ type: 'lyric', command: cmd }, folder));
    }

    resolveTask(task: vscode.Task): vscode.Task | undefined {
        const def = task.definition as LyricTaskDefinition;
        if (def.type !== 'lyric' || !def.command) return undefined;
        const folder: vscode.WorkspaceFolder | undefined =
            task.scope != null && typeof task.scope === 'object' && 'uri' in task.scope
                ? task.scope as vscode.WorkspaceFolder
                : vscode.workspace.workspaceFolders?.[0];
        if (!folder) return undefined;
        return buildTask(def, folder);
    }
}

// Convenience: run a lyric command in an integrated terminal with a progress notification.
export async function runLyricInTerminal(
    args: string[],
    title: string,
    cwd?: string,
): Promise<void> {
    const cli = lyricCli();
    const workspaceCwd = cwd ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? '.';
    await vscode.window.withProgress(
        { location: vscode.ProgressLocation.Notification, title, cancellable: false },
        async () => {
            const terminal = vscode.window.createTerminal({
                name: `Lyric: ${args[0]}`,
                cwd: workspaceCwd,
            });
            terminal.show(false);
            terminal.sendText(`${cli} ${args.map(a => JSON.stringify(a)).join(' ')}`);
        },
    );
}

export async function runLyricRestore(manifestPath?: string): Promise<void> {
    const manifest = manifestPath ?? findManifestInWorkspace();
    const args = manifest ? ['restore', '--manifest', manifest] : ['restore'];
    await runLyricInTerminal(args, 'Lyric: Restore');
}

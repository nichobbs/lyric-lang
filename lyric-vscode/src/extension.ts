import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    const config = vscode.workspace.getConfiguration('lyric');
    const serverPath = config.get<string>('serverPath', 'lyric-lsp');

    const serverOptions: ServerOptions = {
        command: serverPath,
        args: [],
        transport: TransportKind.stdio,
        options: {
            // Inherit PATH so the server can find any tools it needs.
            env: process.env,
        },
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'lyric' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.l'),
        },
        // Forward the trace setting to the language client.
        traceOutputChannel: vscode.window.createOutputChannel('Lyric Language Server Trace'),
    };

    client = new LanguageClient(
        'lyric',
        'Lyric Language Server',
        serverOptions,
        clientOptions,
    );

    try {
        await client.start();
    } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        vscode.window.showErrorMessage(
            `Lyric: failed to start language server (${serverPath}): ${msg}. ` +
            `Set "lyric.serverPath" to the absolute path of the lyric-lsp binary.`,
        );
        return;
    }

    context.subscriptions.push(client);
}

export function deactivate(): Thenable<void> | undefined {
    return client?.stop();
}

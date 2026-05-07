import * as cp from 'child_process';
import * as vscode from 'vscode';

function lyricCli(): string {
    return vscode.workspace.getConfiguration('lyric').get<string>('cliPath', 'lyric');
}

export class LyricDocumentFormatter implements vscode.DocumentFormattingEditProvider {
    provideDocumentFormattingEdits(
        document: vscode.TextDocument,
        _options: vscode.FormattingOptions,
        token: vscode.CancellationToken,
    ): Promise<vscode.TextEdit[]> {
        if (!vscode.workspace.getConfiguration('lyric').get<boolean>('format.enable', true)) {
            return Promise.resolve([]);
        }
        return new Promise((resolve, reject) => {
            const cli = lyricCli();
            const filePath = document.uri.fsPath;
            const cwd = vscode.workspace.getWorkspaceFolder(document.uri)?.uri.fsPath;

            const child = cp.spawn(cli, ['fmt', filePath], { cwd });
            const chunks: Buffer[] = [];
            const errChunks: Buffer[] = [];

            child.stdout.on('data', (d: Buffer) => chunks.push(d));
            child.stderr.on('data', (d: Buffer) => errChunks.push(d));

            token.onCancellationRequested(() => child.kill());

            child.on('close', code => {
                if (token.isCancellationRequested) {
                    resolve([]);
                    return;
                }
                if (code !== 0) {
                    const msg = Buffer.concat(errChunks).toString().trim();
                    // Don't show an error for parse failures — the LSP already shows diagnostics.
                    if (msg) console.error(`lyric fmt: ${msg}`);
                    resolve([]);
                    return;
                }
                const formatted = Buffer.concat(chunks).toString();
                const fullRange = new vscode.Range(
                    document.positionAt(0),
                    document.positionAt(document.getText().length),
                );
                resolve([vscode.TextEdit.replace(fullRange, formatted)]);
            });

            child.on('error', err => {
                vscode.window.showWarningMessage(
                    `Lyric: could not run formatter (${cli}): ${err.message}. ` +
                    `Set "lyric.cliPath" to the lyric binary.`,
                );
                resolve([]);
            });
        });
    }
}

import * as cp from 'child_process';
import * as vscode from 'vscode';

const WARNED_KEY = 'lyric.formatter.commentWarningShown';

function lyricCli(): string {
    return vscode.workspace.getConfiguration('lyric').get<string>('cliPath', 'lyric');
}

export function createFormatter(context: vscode.ExtensionContext): vscode.DocumentFormattingEditProvider {
    return {
        provideDocumentFormattingEdits(
            document: vscode.TextDocument,
            _options: vscode.FormattingOptions,
            token: vscode.CancellationToken,
        ): Promise<vscode.TextEdit[]> {
            if (!vscode.workspace.getConfiguration('lyric').get<boolean>('format.enable', true)) {
                return Promise.resolve([]);
            }

            maybeWarnAboutComments(context);

            return new Promise(resolve => {
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
                        // Parse failures are already shown by the LSP — don't double-report.
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
        },
    };
}

function maybeWarnAboutComments(context: vscode.ExtensionContext): void {
    if (context.globalState.get<boolean>(WARNED_KEY)) return;

    vscode.window.showInformationMessage(
        'Lyric formatter: non-doc // comments are not preserved. ' +
        'The formatter works from the AST; only /// and //! doc comments survive. ' +
        'Use /// for any comment you want to keep.',
        'Got it',
        'Learn more',
    ).then(choice => {
        if (choice === 'Learn more') {
            vscode.env.openExternal(vscode.Uri.parse(
                'https://github.com/nichobbs/lyric-lang/blob/main/lyric-vscode/README.md#formatter',
            ));
        }
    });

    context.globalState.update(WARNED_KEY, true);
}

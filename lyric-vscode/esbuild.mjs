import * as esbuild from 'esbuild';

const watch = process.argv.includes('--watch');
const minify = process.argv.includes('--minify');

const ctx = await esbuild.context({
    entryPoints: ['src/extension.ts'],
    bundle: true,
    outfile: 'dist/extension.js',
    external: ['vscode'],
    format: 'cjs',
    platform: 'node',
    sourcemap: !minify,
    minify,
    logLevel: 'info',
});

if (watch) {
    await ctx.watch();
    console.log('Watching for changes...');
} else {
    await ctx.rebuild();
    await ctx.dispose();
}

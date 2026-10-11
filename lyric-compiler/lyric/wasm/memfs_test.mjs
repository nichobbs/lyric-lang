// Node tests for the in-memory virtual filesystem in glue_runtime.js (docs/35 W3).
//
// They need no wasi-sdk: the glue is loaded with a stub header, and a tiny wasm
// module is assembled here that re-exports the WASI imports the glue satisfies, so
// each WASI call goes through the real import object against real linear memory.
//
//   node lyric-compiler/lyric/wasm/memfs_test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const E = { OK: 0, BADF: 8, EXIST: 20, INVAL: 28, ISDIR: 31, NOENT: 44, NOTDIR: 54, NOTEMPTY: 55, NOTCAPABLE: 76 };
const O = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 };
const R = { READ: 2n, WRITE: 64n, RW: 66n, DIR: 0x4000n };

// i = i32, l = i64; every call returns an i32 errno.
const SIGS = {
  fd_prestat_get: 'ii', fd_prestat_dir_name: 'iii', fd_write: 'iiii', fd_read: 'iiii',
  fd_pwrite: 'iiili', fd_pread: 'iiili', fd_seek: 'ilii', fd_tell: 'ii', fd_close: 'i',
  fd_readdir: 'iiili', fd_filestat_get: 'ii', fd_filestat_set_size: 'il',
  fd_filestat_set_times: 'illi', fd_fdstat_get: 'ii', fd_fdstat_set_flags: 'ii',
  path_open: 'iiiiillii', path_create_directory: 'iii', path_remove_directory: 'iii',
  path_unlink_file: 'iii', path_rename: 'iiiiii', path_filestat_get: 'iiiii',
  path_filestat_set_times: 'iiiilli',
};

const uleb = (n) => {
  const out = [];
  do {
    let b = n & 0x7f;
    n >>>= 7;
    if (n) b |= 0x80;
    out.push(b);
  } while (n);
  return out;
};
const name = (s) => [...uleb(s.length), ...Buffer.from(s)];
const vec = (items) => [...uleb(items.length), ...items.flat()];
const section = (id, body) => [id, ...uleb(body.length), ...body];

function assembleWasm() {
  const names = Object.keys(SIGS);
  const sigKeys = [...new Set([...Object.values(SIGS), ''])];
  const types = sigKeys.map((k) => [0x60, ...vec([...k].map((c) => [c === 'i' ? 0x7f : 0x7e])), ...vec([[0x7f]])]);
  const typeIdx = (k) => sigKeys.indexOf(k);
  const imports = names.map((n, i) => [...name('wasi_snapshot_preview1'), ...name(n), 0x00, ...uleb(typeIdx(SIGS[n]))]);
  const exports = [
    [...name('memory'), 0x02, 0x00],
    [...name('lyric_wasm_abi_version'), 0x00, ...uleb(names.length)],
    ...names.map((n, i) => [...name(n), 0x00, ...uleb(i)]),
  ];
  const body = [0x00, 0x41, 0x02, 0x0b]; // no locals; i32.const 2; end
  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...section(1, vec(types)),
    ...section(2, vec(imports)),
    ...section(3, vec([uleb(typeIdx(''))])),
    ...section(5, vec([[0x00, 0x04]])),
    ...section(7, vec(exports)),
    ...section(10, vec([[...uleb(body.length), ...body]])),
  ]);
}

const here = dirname(fileURLToPath(import.meta.url));
const dir = mkdtempSync(join(tmpdir(), 'lyric-memfs-'));
const glueFile = join(dir, 'glue.mjs');
writeFileSync(
  glueFile,
  "const wasmFile = 'x.wasm'; const LYRIC_EXPORTS = []; const LYRIC_IMPORTS = []; const LYRIC_NPM = {};\n" +
    readFileSync(join(here, 'glue_runtime.js'), 'utf8'),
);
const glue = await import(pathToFileURL(glueFile).href);
const wasmModule = await WebAssembly.compile(assembleWasm());

/** A booted instance plus helpers for staging strings and structs in its memory. */
async function boot(files, options = {}) {
  const lyric = await glue.instantiate(wasmModule, { files, ...options });
  const w = lyric.raw;
  const mem = () => new Uint8Array(lyric.memory.buffer);
  const dv = () => new DataView(lyric.memory.buffer);
  let brk = 4096;
  const alloc = (n) => {
    const p = brk;
    brk += (n + 7) & ~7;
    return p;
  };
  const str = (s) => {
    const b = Buffer.from(s);
    const p = alloc(b.length || 1);
    mem().set(b, p);
    return [p, b.length];
  };
  const text = (s) => {
    const b = Buffer.from(s);
    const p = alloc(b.length || 1);
    mem().set(b, p);
    return { p, len: b.length };
  };
  const u32 = () => alloc(8);
  return {
    lyric, w, mem, dv, alloc, str, text, u32,
    open(path, oflags = 0, rights = R.READ, fdflags = 0, dirfd = 3) {
      const [p, n] = str(path);
      const out = u32();
      const e = w.path_open(dirfd, 0, p, n, oflags, rights, 0n, fdflags, out);
      return { e, fd: e === 0 ? dv().getUint32(out, true) : -1 };
    },
    write(fd, data) {
      const t = text(data);
      const iov = alloc(8);
      dv().setUint32(iov, t.p, true);
      dv().setUint32(iov + 4, t.len, true);
      const out = u32();
      const e = w.fd_write(fd, iov, 1, out);
      return { e, n: dv().getUint32(out, true) };
    },
    read(fd, max) {
      const p = alloc(max || 1);
      const iov = alloc(8);
      dv().setUint32(iov, p, true);
      dv().setUint32(iov + 4, max, true);
      const out = u32();
      const e = w.fd_read(fd, iov, 1, out);
      const n = dv().getUint32(out, true);
      return { e, n, data: Buffer.from(mem().slice(p, p + n)).toString() };
    },
    seek(fd, off, whence) {
      const out = alloc(8);
      const e = w.fd_seek(fd, BigInt(off), whence, out);
      return { e, pos: Number(dv().getBigUint64(out, true)) };
    },
    path(fn, p, ...rest) {
      const [ptr, n] = str(p);
      return w[fn](3, ptr, n, ...rest);
    },
    stat(p) {
      const [ptr, n] = str(p);
      const out = alloc(64);
      const e = w.path_filestat_get(3, 1, ptr, n, out);
      return { e, type: mem()[out + 16], size: Number(dv().getBigUint64(out + 32, true)), mtime: dv().getBigUint64(out + 48, true) };
    },
    readdir(fd, bufLen = 4096, cookie = 0n) {
      const buf = alloc(bufLen);
      const out = u32();
      const e = w.fd_readdir(fd, buf, bufLen, cookie, out);
      const used = dv().getUint32(out, true);
      const names = [];
      let at = 0;
      while (at + 24 <= used) {
        const namlen = dv().getUint32(buf + at + 16, true);
        if (at + 24 + namlen > used) break;
        names.push({ name: Buffer.from(mem().slice(buf + at + 24, buf + at + 24 + namlen)).toString(), type: mem()[buf + at + 20], next: dv().getBigUint64(buf + at, true) });
        at += 24 + namlen;
      }
      return { e, used, names };
    },
  };
}

test('the preopened root is fd 3 named "/" and fd 4 is not a preopen', async () => {
  const h = await boot();
  const p = h.alloc(8);
  assert.equal(h.w.fd_prestat_get(3, p), E.OK);
  assert.equal(h.mem()[p], 0, 'tag: directory');
  assert.equal(h.dv().getUint32(p + 4, true), 1);
  const n = h.alloc(8);
  assert.equal(h.w.fd_prestat_dir_name(3, n, 1), E.OK);
  assert.equal(String.fromCharCode(h.mem()[n]), '/');
  assert.equal(h.w.fd_prestat_get(4, p), E.BADF);
});

test('options.files seeds strings and bytes, creating parent directories', async () => {
  const h = await boot({ '/a.txt': 'alpha', '/d/e/f.bin': new Uint8Array([1, 2, 3]), 'rel.txt': 'r', '/empty/': null });
  const a = h.open('a.txt');
  assert.equal(a.e, E.OK);
  assert.equal(h.read(a.fd, 100).data, 'alpha');
  assert.equal(h.stat('d/e').type, 3);
  assert.equal(h.stat('d/e/f.bin').size, 3);
  assert.equal(h.stat('rel.txt').size, 1);
  assert.equal(h.stat('empty').type, 3);
  assert.deepEqual(h.lyric.files.list('/'), ['a.txt', 'd', 'rel.txt', 'empty']);
});

test('a Map seeds the filesystem as well', async () => {
  const h = await boot(new Map([['x/y.txt', 'mapped']]));
  assert.equal(h.lyric.files.readText('/x/y.txt'), 'mapped');
});

test('read advances the position, stops at end of file, and seek repositions', async () => {
  const h = await boot({ '/s.txt': '0123456789' });
  const { fd } = h.open('s.txt');
  assert.equal(h.read(fd, 4).data, '0123');
  assert.equal(h.read(fd, 4).data, '4567');
  assert.equal(h.read(fd, 4).data, '89');
  assert.equal(h.read(fd, 4).n, 0);
  assert.deepEqual(h.seek(fd, 2, 0), { e: 0, pos: 2 });
  assert.equal(h.read(fd, 3).data, '234');
  assert.deepEqual(h.seek(fd, -2, 1), { e: 0, pos: 3 });
  assert.deepEqual(h.seek(fd, -1, 2), { e: 0, pos: 9 });
  assert.equal(h.read(fd, 5).data, '9');
  assert.equal(h.seek(fd, -100, 1).e, E.INVAL);
  assert.equal(h.seek(fd, 0, 7).e, E.INVAL);
  const t = h.alloc(8);
  assert.equal(h.w.fd_tell(fd, t), E.OK);
  assert.equal(h.dv().getBigUint64(t, true), 10n);
});

test('create, write, close; the host reads the bytes back', async () => {
  const h = await boot();
  const f = h.open('out.txt', O.CREAT, R.WRITE);
  assert.equal(f.e, E.OK);
  assert.deepEqual(h.write(f.fd, 'hello, '), { e: 0, n: 7 });
  assert.deepEqual(h.write(f.fd, 'world'), { e: 0, n: 5 });
  assert.equal(h.w.fd_close(f.fd), E.OK);
  assert.equal(h.lyric.files.readText('/out.txt'), 'hello, world');
  assert.deepEqual(Object.keys(h.lyric.files.snapshot()), ['/out.txt']);
  assert.equal(h.w.fd_close(f.fd), E.BADF, 'closed twice');
});

test('a write past the end zero-fills the gap', async () => {
  const h = await boot({ '/g.bin': 'ab' });
  const f = h.open('g.bin', 0, R.RW);
  h.seek(f.fd, 5, 0);
  h.write(f.fd, 'Z');
  assert.deepEqual([...h.lyric.files.read('/g.bin')], [97, 98, 0, 0, 0, 90]);
});

test('append writes go to the end whatever the position', async () => {
  const h = await boot({ '/log.txt': 'one\n' });
  const f = h.open('log.txt', 0, R.WRITE, 1);
  h.seek(f.fd, 0, 0);
  h.write(f.fd, 'two\n');
  assert.equal(h.lyric.files.readText('/log.txt'), 'one\ntwo\n');
});

test('truncate on open empties the file, and O_EXCL refuses an existing one', async () => {
  const h = await boot({ '/t.txt': 'old contents' });
  assert.equal(h.open('t.txt', O.CREAT | O.EXCL, R.WRITE).e, E.EXIST);
  const f = h.open('t.txt', O.TRUNC, R.WRITE);
  assert.equal(f.e, E.OK);
  h.write(f.fd, 'new');
  assert.equal(h.lyric.files.readText('/t.txt'), 'new');
});

test('open errors: missing, directory as file, file as directory, missing parent', async () => {
  const h = await boot({ '/f.txt': 'x', '/dir/': null });
  assert.equal(h.open('nope.txt').e, E.NOENT);
  assert.equal(h.open('nope/deeper.txt', O.CREAT, R.WRITE).e, E.NOENT);
  assert.equal(h.open('f.txt', O.DIRECTORY).e, E.NOTDIR);
  assert.equal(h.open('f.txt/child').e, E.NOTDIR);
  assert.equal(h.open('dir', 0, R.WRITE).e, E.ISDIR);
  assert.equal(h.open('f.txt/').e, E.NOTDIR);
  assert.equal(h.open('').e, E.NOENT);
  assert.equal(h.open('dir', O.DIRECTORY, R.DIR).e, E.OK);
});

test('descriptors honour the rights they were opened with', async () => {
  const h = await boot({ '/f.txt': 'data' });
  const ro = h.open('f.txt', 0, R.READ);
  assert.equal(h.write(ro.fd, 'x').e, E.BADF);
  const wo = h.open('f.txt', 0, R.WRITE);
  assert.equal(h.read(wo.fd, 1).e, E.BADF);
  assert.equal(h.read(99, 1).e, E.BADF);
  const dir = h.open('.', O.DIRECTORY, R.DIR);
  assert.equal(h.read(dir.fd, 1).e, E.ISDIR);
});

test('paths cannot leave the preopened root', async () => {
  const h = await boot({ '/f.txt': 'x', '/d/g.txt': 'y' });
  assert.equal(h.open('../f.txt').e, E.NOTCAPABLE);
  assert.equal(h.open('d/../../f.txt').e, E.NOTCAPABLE);
  assert.equal(h.open('/f.txt').e, E.NOTCAPABLE);
  assert.equal(h.open('d/../f.txt').e, E.OK, '.. inside the tree is fine');
  assert.equal(h.open('./d/./g.txt').e, E.OK);
  const d = h.open('d', O.DIRECTORY, R.DIR);
  assert.equal(h.open('../f.txt', 0, R.READ, 0, d.fd).e, E.OK, '.. from a subdirectory descriptor');
  assert.throws(() => h.lyric.files.read('/d/../f.txt'), /EINVAL/);
});

test('readdir lists . and .. first, then the entries with their types, and resumes from a cookie', async () => {
  const h = await boot({ '/a.txt': '1', '/sub/b.txt': '2', '/c.txt': '3' });
  const dir = h.open('.', O.DIRECTORY, R.DIR);
  const all = h.readdir(dir.fd);
  assert.deepEqual(all.names.map((n) => n.name), ['.', '..', 'a.txt', 'sub', 'c.txt']);
  assert.deepEqual(all.names.map((n) => n.type), [3, 3, 4, 3, 4]);
  const from = h.readdir(dir.fd, 4096, all.names[2].next);
  assert.deepEqual(from.names.map((n) => n.name), ['sub', 'c.txt']);
  assert.equal(h.readdir(dir.fd, 4096, 5n).used, 0, 'cookie at the end');
  // A buffer smaller than the listing fills completely, so the caller knows to ask again.
  const small = h.readdir(dir.fd, 40);
  assert.equal(small.used, 40);
  assert.equal(h.readdir(h.open('a.txt').fd).e, E.NOTDIR);
});

test('mkdir, rmdir, unlink and their errors', async () => {
  const h = await boot({ '/dir/inner.txt': 'x', '/file.txt': 'y' });
  assert.equal(h.path('path_create_directory', 'made'), E.OK);
  assert.equal(h.path('path_create_directory', 'made'), E.EXIST);
  assert.equal(h.path('path_create_directory', 'file.txt'), E.EXIST);
  assert.equal(h.path('path_create_directory', 'no/parent'), E.NOENT);
  assert.equal(h.path('path_remove_directory', 'dir'), E.NOTEMPTY);
  assert.equal(h.path('path_remove_directory', 'file.txt'), E.NOTDIR);
  assert.equal(h.path('path_remove_directory', 'gone'), E.NOENT);
  assert.equal(h.path('path_remove_directory', 'made'), E.OK);
  assert.equal(h.stat('made').e, E.NOENT);
  assert.equal(h.path('path_unlink_file', 'dir'), E.ISDIR);
  assert.equal(h.path('path_unlink_file', 'dir/inner.txt'), E.OK);
  assert.equal(h.path('path_remove_directory', 'dir'), E.OK);
  assert.equal(h.path('path_unlink_file', 'file.txt'), E.OK);
  assert.equal(h.path('path_unlink_file', 'file.txt'), E.NOENT);
  assert.equal(h.path('path_remove_directory', '.'), E.INVAL, 'the root stays');
  assert.deepEqual(h.lyric.files.list('/'), []);
});

test('an open descriptor keeps working after its file is unlinked', async () => {
  const h = await boot({ '/f.txt': 'still here' });
  const { fd } = h.open('f.txt');
  assert.equal(h.path('path_unlink_file', 'f.txt'), E.OK);
  assert.equal(h.read(fd, 100).data, 'still here');
});

test('rename moves files and directories, replaces a file, and refuses bad moves', async () => {
  const h = await boot({ '/a.txt': 'A', '/b.txt': 'B', '/d/x.txt': 'X', '/e/': null, '/e2/keep.txt': 'k' });
  const rename = (from, to) => {
    const [fp, fn] = h.str(from);
    const [tp, tn] = h.str(to);
    return h.w.path_rename(3, fp, fn, 3, tp, tn);
  };
  assert.equal(rename('a.txt', 'moved.txt'), E.OK);
  assert.equal(h.lyric.files.readText('/moved.txt'), 'A');
  assert.equal(h.lyric.files.exists('/a.txt'), false);
  assert.equal(rename('moved.txt', 'b.txt'), E.OK, 'replaces an existing file');
  assert.equal(h.lyric.files.readText('/b.txt'), 'A');
  assert.equal(rename('d', 'e/d2'), E.OK, 'moves a directory with its contents');
  assert.equal(h.lyric.files.readText('/e/d2/x.txt'), 'X');
  assert.equal(h.open('e/d2/../d2/x.txt').e, E.OK, '.. follows the new parent');
  assert.equal(rename('e', 'e/d2/inside'), E.INVAL, 'into itself');
  assert.equal(rename('b.txt', 'e'), E.ISDIR);
  assert.equal(rename('e', 'b.txt'), E.NOTDIR);
  assert.equal(rename('e', 'e2'), E.NOTEMPTY);
  assert.equal(rename('nope', 'x'), E.NOENT);
  assert.equal(rename('b.txt', 'b.txt'), E.OK);
});

test('filestat: type and size by path and by descriptor, truncate, and set_times', async () => {
  const h = await boot({ '/f.txt': 'twelve bytes', '/dir/': null });
  assert.deepEqual([h.stat('f.txt').type, h.stat('f.txt').size], [4, 12]);
  assert.equal(h.stat('dir').type, 3);
  assert.equal(h.stat('missing').e, E.NOENT);
  const f = h.open('f.txt', 0, R.RW);
  const out = h.alloc(64);
  assert.equal(h.w.fd_filestat_get(f.fd, out), E.OK);
  assert.equal(Number(h.dv().getBigUint64(out + 32, true)), 12);
  assert.equal(h.w.fd_filestat_set_size(f.fd, 5n), E.OK);
  assert.equal(h.lyric.files.readText('/f.txt'), 'twelv');
  assert.equal(h.w.fd_filestat_set_size(f.fd, 8n), E.OK);
  assert.deepEqual([...h.lyric.files.read('/f.txt')].slice(5), [0, 0, 0], 'growing zero-fills, even over bytes cut earlier');
  // mtime: explicit, then "now".
  const [pp, pn] = h.str('f.txt');
  assert.equal(h.w.path_filestat_set_times(3, 1, pp, pn, 0n, 1234567890000000000n, 4), E.OK);
  assert.equal(h.stat('f.txt').mtime, 1234567890000000000n);
  assert.equal(h.w.path_filestat_set_times(3, 1, pp, pn, 0n, 0n, 8), E.OK);
  assert.ok(h.stat('f.txt').mtime > 1234567890000000000n);
  h.write(f.fd, 'x');
  assert.ok(h.stat('f.txt').mtime >= 1234567890000000000n);
});

test('pread and pwrite use their own offset and leave the position alone', async () => {
  const h = await boot({ '/p.txt': 'abcdef' });
  const f = h.open('p.txt', 0, R.RW);
  const buf = h.alloc(8);
  const iov = h.alloc(8);
  h.dv().setUint32(iov, buf, true);
  h.dv().setUint32(iov + 4, 3, true);
  const out = h.u32();
  assert.equal(h.w.fd_pread(f.fd, iov, 1, 2n, out), E.OK);
  assert.equal(Buffer.from(h.mem().slice(buf, buf + 3)).toString(), 'cde');
  const t = h.text('XY');
  h.dv().setUint32(iov, t.p, true);
  h.dv().setUint32(iov + 4, t.len, true);
  assert.equal(h.w.fd_pwrite(f.fd, iov, 1, 1n, out), E.OK);
  assert.equal(h.lyric.files.readText('/p.txt'), 'aXYdef');
  assert.equal(h.read(f.fd, 2).data, 'aX', 'position untouched');
});

test('fdstat reports the file type, and set_flags toggles append', async () => {
  const h = await boot({ '/f.txt': 'x' });
  const f = h.open('f.txt', 0, R.WRITE);
  const out = h.alloc(24);
  assert.equal(h.w.fd_fdstat_get(f.fd, out), E.OK);
  assert.equal(h.mem()[out], 4);
  assert.equal(h.dv().getUint16(out + 2, true), 0);
  assert.equal(h.w.fd_fdstat_set_flags(f.fd, 1), E.OK);
  h.w.fd_fdstat_get(f.fd, out);
  assert.equal(h.dv().getUint16(out + 2, true), 1);
  assert.equal(h.w.fd_fdstat_get(3, out), E.OK);
  assert.equal(h.mem()[out], 3);
  assert.equal(h.w.fd_fdstat_get(50, out), E.BADF);
});

test('descriptor numbers are reused after close, starting at 4', async () => {
  const h = await boot({ '/f.txt': 'x' });
  const a = h.open('f.txt');
  const b = h.open('f.txt');
  assert.deepEqual([a.fd, b.fd], [4, 5]);
  h.w.fd_close(a.fd);
  assert.equal(h.open('f.txt').fd, 4);
});

test('stdio is unaffected: fd 1 still reaches options.stdout, and fd 0 is not a file', async () => {
  const seen = [];
  const h = await boot(undefined, { stdout: (t) => seen.push(t) });
  assert.deepEqual(h.write(1, 'to stdout'), { e: 0, n: 9 });
  assert.deepEqual(seen, ['to stdout']);
  assert.equal(h.w.fd_close(1), E.OK);
  assert.equal(h.w.fd_close(40), E.BADF);
  assert.equal(h.w.fd_filestat_get(1, h.alloc(64)), E.OK);
});

test('lyric.files: write creates parents, list/exists/read answer for missing paths, text round-trips UTF-8', async () => {
  const h = await boot();
  const files = h.lyric.files;
  files.write('/deep/er/file.txt', 'héllo ✓');
  assert.equal(files.readText('deep/er/file.txt'), 'héllo ✓');
  assert.deepEqual(files.list('/deep'), ['er']);
  assert.equal(files.exists('/deep/er'), true);
  assert.equal(files.exists('/nope'), false);
  assert.equal(files.read('/nope'), undefined);
  assert.equal(files.readText('/deep'), undefined, 'a directory is not a file');
  assert.equal(files.list('/deep/er/file.txt'), undefined, 'a file is not a directory');
  assert.throws(() => files.write('/deep/er/file.txt/x', 'y'), /ENOTDIR/);
  assert.throws(() => files.write('/deep', 'y'), /EISDIR/);
  files.mkdir('/only/dirs');
  assert.deepEqual(files.list('/only'), ['dirs']);
  assert.equal(files.read('/deep/er/file.txt').constructor, Uint8Array);
  // A host write is visible to a guest read, and the seed is copied, not aliased.
  const seed = new Uint8Array([1, 2, 3]);
  const g = await boot({ '/s.bin': seed });
  seed[0] = 99;
  assert.deepEqual([...g.lyric.files.read('/s.bin')], [1, 2, 3]);
  g.lyric.files.write('/late.txt', 'added after boot');
  assert.equal(g.read(g.open('late.txt').fd, 100).data, 'added after boot');
});

test('seed values of the wrong type are rejected', async () => {
  await assert.rejects(() => boot({ '/bad': 42 }), /file contents must be/);
});

test('growing a file past its capacity keeps the earlier bytes', async () => {
  const h = await boot();
  const f = h.open('big.txt', O.CREAT, R.WRITE);
  const chunk = 'x'.repeat(1000);
  for (let i = 0; i < 100; i++) h.write(f.fd, chunk);
  assert.equal(h.lyric.files.read('/big.txt').length, 100000);
  assert.equal(h.stat('big.txt').size, 100000);
});

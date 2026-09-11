'use strict';
/**
 * patch_tls.js —— 将 aarch64 .so 中 Go runtime 的唯一一条 IE-TLS 重定位
 * R_AARCH64_TLS_TPREL64 (type=1030) 改为 R_AARCH64_NONE (0)，
 * 以规避 OHOS musl 加载器的 "initial-exec TLS resolves to dynamic definition"。
 *
 * 该重定位对应 runtime.tls_g，每个 Go 二进制有且仅有一条，与业务代码规模无关。
 *
 * 用法: node patch_tls.js <path-to.so> [--check]
 *   默认就地 patch；--check 只统计不改。
 * 退出码: 0 成功/无需改；1 出错(找到 0 或 >1 条时按策略处理)。
 */
const fs = require('fs');

const R_AARCH64_TLS_TPREL64 = 1030n;
const R_AARCH64_NONE = 0n;
const SHT_RELA = 4;

function patch(soPath, checkOnly) {
  const buf = fs.readFileSync(soPath);

  // ELF64 magic
  if (buf[0] !== 0x7f || buf[1] !== 0x45 || buf[2] !== 0x4c || buf[3] !== 0x46) {
    throw new Error('not an ELF file: ' + soPath);
  }
  const e_shoff = Number(buf.readBigUInt64LE(0x28));
  const e_shentsize = buf.readUInt16LE(0x3a);
  const e_shnum = buf.readUInt16LE(0x3c);

  const relaSecs = [];
  for (let i = 0; i < e_shnum; i++) {
    const base = e_shoff + i * e_shentsize;
    const sh_type = buf.readUInt32LE(base + 4);
    if (sh_type === SHT_RELA) {
      const sh_offset = Number(buf.readBigUInt64LE(base + 0x18));
      const sh_size = Number(buf.readBigUInt64LE(base + 0x20));
      let sh_entsize = Number(buf.readBigUInt64LE(base + 0x38));
      if (!sh_entsize) sh_entsize = 24;
      relaSecs.push({ sh_offset, sh_size, sh_entsize });
    }
  }

  const found = [];
  for (const s of relaSecs) {
    const n = Math.floor(s.sh_size / s.sh_entsize);
    for (let i = 0; i < n; i++) {
      const off = s.sh_offset + i * s.sh_entsize;
      const r_info = buf.readBigUInt64LE(off + 8);
      const r_type = r_info & 0xffffffffn;
      if (r_type === R_AARCH64_TLS_TPREL64) {
        found.push({ off, r_info, r_sym: r_info >> 32n });
      }
    }
  }

  console.log(`[patch_tls] ${soPath}: rela sections=${relaSecs.length}, TPREL64 found=${found.length}`);
  for (const f of found) {
    console.log(`  fileoff=0x${f.off.toString(16)} r_sym=${f.r_sym}`);
  }

  if (checkOnly) return found.length;

  if (found.length === 0) {
    console.log('[patch_tls] nothing to patch (already 0). OK.');
    return 0;
  }
  if (found.length > 1) {
    throw new Error(`expected at most 1 TPREL64, got ${found.length}; refusing unsafe patch`);
  }
  for (const f of found) {
    const newInfo = (f.r_sym << 32n) | R_AARCH64_NONE;
    buf.writeBigUInt64LE(newInfo, f.off + 8);
  }
  fs.writeFileSync(soPath, buf);
  console.log(`[patch_tls] PATCHED ${found.length} reloc(s) -> NONE`);
  return 0;
}

const args = process.argv.slice(2);
if (args.length < 1) {
  console.error('usage: node patch_tls.js <path-to.so> [--check]');
  process.exit(2);
}
const checkOnly = args.includes('--check');
try {
  patch(args[0], checkOnly);
  process.exit(0);
} catch (e) {
  console.error('[patch_tls] ERROR:', e.message);
  process.exit(1);
}

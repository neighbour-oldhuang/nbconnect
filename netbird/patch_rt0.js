'use strict';
/**
 * patch_rt0.js —— 让 Go runtime 不再读进程 argv/envp。
 *
 * 背景：-buildmode=c-archive 的 Go runtime 由 .init_array 构造函数 _rt0_arm64_lib
 * 启动，它从寄存器 R0/R1 取 argc/argv：
 *
 *     adrp x27, page(_rt0_arm64_lib_argc)
 *     str  x0,  [x27, #off_argc]      ; argc = R0
 *     adrp x27, page(_rt0_arm64_lib_argv)
 *     str  x1,  [x27, #off_argv]      ; argv = R1
 *
 * OHOS musl 通过 dlopen 调 .init_array 时不传 (argc, argv, envp)，R0/R1 是残值。
 * runtime.schedinit -> runtime.getGodebugEarly 会拿这个假 argv 去遍历 envp 找
 * GODEBUG=，proc.go 里 argv_index() 没有空指针守卫，于是把字符串字节当指针解引用：
 * HarmonyOS 6.1 上 SIGSEGV(SEGV_MAPERR)@0x00444f4d5f4c4140（小端即 ASCII "@AL_MOD"），
 * 7.0 上残值恰好让遍历提前撞到 NULL，属于侥幸能跑。
 *
 * 本脚本原地改两条指令（不新增任何重定位，ADRP 是 PC 相对，天然适配 PIE）：
 *
 *     str  x0,  [x27, #off_argc]  ->  str  xzr, [x27, #off_argc]   ; argc = 0
 *     adrp x27, page(argv)        ->  adrp x1,  page(kGoZeroArgv)  ; x1 = &kGoZeroArgv
 *     str  x1,  [x27, #off_argv]      (不动：x27 仍是第一条 adrp 设的页基址)
 *
 * 第二条 adrp 与第一条同页、本就是冗余的，正好腾出来装载零区地址。kGoZeroArgv 由
 * napi_init.cpp 定义，4096 对齐、全零，因此 argv[0..] 全是 NULL：sysargs、
 * getGodebugEarly、goenvs_unix 的遍历第一步就结束。auxv 为空时 Go 会回退去读
 * /proc/self/auxv 取页大小与 HWCAP，runtime 初始化不受影响。
 *
 * 用法: node patch_rt0.js <path-to.so> [--check]
 *   默认就地 patch（已 patch 过则跳过）；--check 只检测不改。
 * 退出码: 0 成功/无需改；1 出错（找不到符号或指令序列不匹配时拒绝改）。
 */
const fs = require('fs');

const SHT_SYMTAB = 2;
const SHT_NOBITS = 8;
const ZERO_ARGV_SYMBOL = 'kGoZeroArgv';
const RT0_SYMBOL = '_rt0_arm64_lib';
const ARGC_SYMBOL = '_rt0_arm64_lib_argc';
const ARGV_SYMBOL = '_rt0_arm64_lib_argv';
// argc/argv 的保存动作在函数开头，前 64 条指令足够覆盖寄存器保存序列。
const SCAN_INSNS = 64;
// argv 至少要能被读到 argv[3]（sysargs 读 auxv 的第一个 tag/val 对），留足余量。
const ZERO_ARGV_MIN_SIZE = 32;

function readSections(buf) {
  if (buf[0] !== 0x7f || buf[1] !== 0x45 || buf[2] !== 0x4c || buf[3] !== 0x46) {
    throw new Error('not an ELF file');
  }
  const e_shoff = Number(buf.readBigUInt64LE(0x28));
  const e_shentsize = buf.readUInt16LE(0x3a);
  const e_shnum = buf.readUInt16LE(0x3c);

  const sections = [];
  for (let i = 0; i < e_shnum; i++) {
    const base = e_shoff + i * e_shentsize;
    sections.push({
      index: i,
      type: buf.readUInt32LE(base + 4),
      addr: Number(buf.readBigUInt64LE(base + 0x10)),
      offset: Number(buf.readBigUInt64LE(base + 0x18)),
      size: Number(buf.readBigUInt64LE(base + 0x20)),
      link: buf.readUInt32LE(base + 0x28),
      entsize: Number(buf.readBigUInt64LE(base + 0x38)),
    });
  }
  return sections;
}

// 只在有 .symtab 的未 strip 产物上工作：argc/argv/rt0 都是 local 符号，不在 .dynsym 里。
function readSymbols(buf, sections) {
  const symtab = sections.find((s) => s.type === SHT_SYMTAB);
  if (!symtab) {
    throw new Error('no .symtab (需要未 strip 的 .so；请在 Hvigor DoNativeStrip 之前 patch)');
  }
  const strtab = sections[symtab.link];
  if (!strtab) {
    throw new Error('.symtab 的 sh_link 无效');
  }

  const entsize = symtab.entsize || 24;
  const count = Math.floor(symtab.size / entsize);
  const symbols = new Map();
  for (let i = 0; i < count; i++) {
    const base = symtab.offset + i * entsize;
    const nameOff = buf.readUInt32LE(base);
    if (nameOff === 0) continue;
    let end = strtab.offset + nameOff;
    while (end < buf.length && buf[end] !== 0) end++;
    const name = buf.toString('utf8', strtab.offset + nameOff, end);
    if (symbols.has(name)) continue;
    symbols.set(name, {
      value: Number(buf.readBigUInt64LE(base + 8)),
      size: Number(buf.readBigUInt64LE(base + 16)),
    });
  }
  return symbols;
}

function vaddrToFileOffset(sections, vaddr) {
  for (const s of sections) {
    if (s.type === SHT_NOBITS || s.addr === 0) continue;
    if (vaddr >= s.addr && vaddr < s.addr + s.size) {
      return s.offset + (vaddr - s.addr);
    }
  }
  throw new Error(`虚拟地址 0x${vaddr.toString(16)} 不在任何有文件内容的节里`);
}

function decodeAdrp(word, pc) {
  if ((word & 0x9f000000) >>> 0 !== 0x90000000) return null;
  const immlo = (word >>> 29) & 0x3;
  const immhi = (word >>> 5) & 0x7ffff;
  let imm = (immhi << 2) | immlo;
  if (imm & 0x100000) imm -= 0x200000; // 21 位符号扩展
  return { rd: word & 0x1f, target: (pc & ~0xfff) + imm * 0x1000 };
}

function encodeAdrp(rd, pc, target) {
  const imm = ((target & ~0xfff) - (pc & ~0xfff)) / 0x1000;
  if (!Number.isInteger(imm) || imm < -0x100000 || imm > 0xfffff) {
    throw new Error(`ADRP 立即数越界: ${imm}`);
  }
  const enc = imm & 0x1fffff;
  return (0x90000000 | ((enc & 0x3) << 29) | (((enc >> 2) & 0x7ffff) << 5) | rd) >>> 0;
}

// STR <Xt>, [<Xn>, #imm12*8]，64 位无符号偏移形式
function decodeStr64(word) {
  if ((word & 0xffc00000) >>> 0 !== 0xf9000000) return null;
  return {
    rt: word & 0x1f,
    rn: (word >>> 5) & 0x1f,
    offset: ((word >>> 10) & 0xfff) * 8,
  };
}

function patch(soPath, checkOnly) {
  const buf = fs.readFileSync(soPath);
  const sections = readSections(buf);
  const symbols = readSymbols(buf, sections);

  for (const name of [RT0_SYMBOL, ARGC_SYMBOL, ARGV_SYMBOL, ZERO_ARGV_SYMBOL]) {
    if (!symbols.has(name)) {
      throw new Error(`符号缺失: ${name}`);
    }
  }

  const rt0 = symbols.get(RT0_SYMBOL);
  const argcAddr = symbols.get(ARGC_SYMBOL).value;
  const argvAddr = symbols.get(ARGV_SYMBOL).value;
  const zeroArgv = symbols.get(ZERO_ARGV_SYMBOL);

  if (zeroArgv.value % 0x1000 !== 0) {
    throw new Error(`${ZERO_ARGV_SYMBOL} 未按 4096 对齐 (0x${zeroArgv.value.toString(16)})`);
  }
  if (zeroArgv.size < ZERO_ARGV_MIN_SIZE) {
    throw new Error(`${ZERO_ARGV_SYMBOL} 太小: ${zeroArgv.size} < ${ZERO_ARGV_MIN_SIZE}`);
  }

  const rt0Off = vaddrToFileOffset(sections, rt0.value);
  const limit = Math.min(SCAN_INSNS, Math.floor((rt0.size || SCAN_INSNS * 4) / 4));

  // 找 [adrp Rd, page(argc)] [str x0, [Rd,#off]] [adrp Rd2, page(argv)] [str x1, [Rd2,#off]]
  let hit = null;
  let alreadyPatched = false;
  for (let i = 0; i + 3 < limit; i++) {
    const pc0 = rt0.value + i * 4;
    const a0 = decodeAdrp(buf.readUInt32LE(rt0Off + i * 4), pc0);
    if (!a0) continue;
    const s0 = decodeStr64(buf.readUInt32LE(rt0Off + (i + 1) * 4));
    if (!s0 || s0.rn !== a0.rd || a0.target + s0.offset !== argcAddr) continue;

    const pc2 = rt0.value + (i + 2) * 4;
    const a1 = decodeAdrp(buf.readUInt32LE(rt0Off + (i + 2) * 4), pc2);
    const s1 = decodeStr64(buf.readUInt32LE(rt0Off + (i + 3) * 4));

    if (s0.rt === 31 && a1 && a1.rd === 1 && s1 && s1.rt === 1 &&
        a1.target === zeroArgv.value && s1.rn === a0.rd &&
        a0.target + s1.offset === argvAddr) {
      alreadyPatched = true;
      break;
    }

    if (s0.rt !== 0) continue;
    if (!a1 || !s1 || s1.rt !== 1 || s1.rn !== a1.rd) continue;
    if (a1.target + s1.offset !== argvAddr) continue;
    // 关键前提：两条 adrp 的目标寄存器相同且同页，第二条才是冗余的、可以被征用
    if (a1.rd !== a0.rd || (a1.target & ~0xfff) !== (a0.target & ~0xfff)) {
      throw new Error('两条 adrp 不同寄存器/不同页，改了会破坏 str 的基址寄存器，拒绝 patch');
    }
    hit = { i, rd: a0.rd, strArgcOff: rt0Off + (i + 1) * 4, adrpArgvOff: rt0Off + (i + 2) * 4, pc2 };
    break;
  }

  console.log(`[patch_rt0] ${soPath}`);
  console.log(`  ${RT0_SYMBOL}=0x${rt0.value.toString(16)} ${ARGC_SYMBOL}=0x${argcAddr.toString(16)} ` +
    `${ARGV_SYMBOL}=0x${argvAddr.toString(16)}`);
  console.log(`  ${ZERO_ARGV_SYMBOL}=0x${zeroArgv.value.toString(16)} size=${zeroArgv.size}`);

  if (alreadyPatched) {
    console.log('[patch_rt0] 已经是 patch 后的形态，跳过。');
    return 0;
  }
  if (!hit) {
    throw new Error('未找到 argc/argv 保存序列，拒绝 patch（Go 版本变化时需要重新核对）');
  }
  console.log(`  命中序列于第 ${hit.i} 条指令，基址寄存器 x${hit.rd}`);

  if (checkOnly) {
    console.log('[patch_rt0] --check：待 patch。');
    return 0;
  }

  const strArgc = buf.readUInt32LE(hit.strArgcOff);
  buf.writeUInt32LE(((strArgc & ~0x1f) | 31) >>> 0, hit.strArgcOff); // Rt -> xzr
  buf.writeUInt32LE(encodeAdrp(1, hit.pc2, zeroArgv.value), hit.adrpArgvOff); // adrp x1, &kGoZeroArgv
  fs.writeFileSync(soPath, buf);
  console.log('[patch_rt0] PATCHED: argc=0, argv=&kGoZeroArgv');
  return 0;
}

const args = process.argv.slice(2);
if (args.length < 1) {
  console.error('usage: node patch_rt0.js <path-to.so> [--check]');
  process.exit(2);
}
try {
  patch(args[0], args.includes('--check'));
  process.exit(0);
} catch (e) {
  console.error('[patch_rt0] ERROR:', e.message);
  process.exit(1);
}

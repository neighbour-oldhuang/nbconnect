import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';

// Multiple server configurations are supported. Each profile owns its own Core
// files so switching the active profile never mixes peer identities:
//
//   netbird-private-<id>.json            configuration and private key
//   netbird-state-<id>.json              peer registration state
//   netbird-credential-import.json       one-time setup key transfer
//
// The setup key transfer file is the one exception: the Core validates its exact
// basename, so a per-profile name made every import fail with "invalid HarmonyOS
// credential import path" and left the profile without an identity. It stays a
// single shared file, which is safe because the Core consumes and deletes it at
// the start of the authentication that immediately follows the import. Callers
// must still purge a leftover file when the active profile changes so a key typed
// for one profile can never register another.
const PROFILE_INDEX_FILE = 'nbconnect-profiles.json';
const CREDENTIAL_IMPORT_FILE = 'netbird-credential-import.json';

export interface VpnProfile {
  id: string;
  name: string;
  managementUrl: string;
}

export interface VpnProfileIndex {
  activeId: string;
  profiles: VpnProfile[];
}

export function createProfileId(): string {
  return `p${Date.now()}${Math.floor(Math.random() * 1000)}`;
}

function indexPath(filesDir: string): string {
  return `${filesDir}/${PROFILE_INDEX_FILE}`;
}

export function readProfileIndex(filesDir: string): VpnProfileIndex {
  const empty: VpnProfileIndex = { activeId: '', profiles: [] };
  try {
    const path = indexPath(filesDir);
    if (!fileIo.accessSync(path)) {
      return empty;
    }
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size = fileIo.statSync(file.fd).size;
      if (size <= 0 || size > 262144) {
        return empty;
      }
      const raw = new ArrayBuffer(size);
      const read = fileIo.readSync(file.fd, raw);
      // 写入走 fileIo.writeSync(fd, string)，默认按 UTF-8 编码，这里必须按 UTF-8 解回来。
      // 原先用 String.fromCharCode 是把每个字节当一个 UTF-16 码元（等于 Latin-1 解码），
      // 中文配置名一个字 3 字节会变成 3 个乱码字符。
      const text = buffer.from(raw, 0, read).toString('utf-8');
      const parsed = JSON.parse(text) as VpnProfileIndex;
      const profiles = parsed.profiles ?? [];
      return { activeId: parsed.activeId ?? '', profiles: profiles };
    } finally {
      fileIo.closeSync(file);
    }
  } catch (_) {
    return empty;
  }
}

export function writeProfileIndex(filesDir: string, index: VpnProfileIndex): void {
  const path = indexPath(filesDir);
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
    fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, JSON.stringify(index));
    fileIo.fsyncSync(file.fd);
  } finally {
    fileIo.closeSync(file);
  }
}

// A profile id is generated locally and must stay filesystem safe.
function safeId(id: string): string {
  return /^[A-Za-z0-9_-]{1,64}$/.test(id) ? id : 'default';
}

export function profileConfigPath(filesDir: string, id: string): string {
  return `${filesDir}/netbird-private-${safeId(id)}.json`;
}

export function profileStatePath(filesDir: string, id: string): string {
  return `${filesDir}/netbird-state-${safeId(id)}.json`;
}

// The Core rejects any other basename for the setup key transfer file, so this
// path is shared by all profiles instead of carrying the profile id.
export function credentialImportPath(filesDir: string): string {
  return `${filesDir}/${CREDENTIAL_IMPORT_FILE}`;
}

export function credentialImportFileName(): string {
  return CREDENTIAL_IMPORT_FILE;
}

// Earlier builds wrote one transfer file per profile. The Core never accepted
// those names, so they only linger as unusable leftovers and are removed.
export function legacyProfileCredentialFileName(id: string): string {
  return `netbird-credential-import-${safeId(id)}.json`;
}

export function profileLogPath(filesDir: string): string {
  return `${filesDir}/netbird.log`;
}

export function activeProfileId(filesDir: string): string {
  const index = readProfileIndex(filesDir);
  if (index.activeId.length > 0) {
    return index.activeId;
  }
  return index.profiles.length > 0 ? index.profiles[0].id : 'default';
}

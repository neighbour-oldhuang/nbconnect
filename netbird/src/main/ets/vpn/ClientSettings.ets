import { fileIo } from '@kit.CoreFileKit';

// 客户端设置是全局的：手机上多份服务器配置通常是同一套使用习惯。
// 文件由 UI 进程写、UI 与 VPN 扩展两个进程都读，扩展在准备前把它交给 Core，
// Core 再把其中属于 NetBird 配置的部分合并进当前 profile 的 config。
const SETTINGS_FILE = 'nbconnect-settings.json';

// 交给 Core 的字段（对应 NetBird 配置项）
export interface CoreClientSettings {
  manageDns: boolean;
  acceptRoutes: boolean;
  blockLanAccess: boolean;
  blockInbound: boolean;
  rosenpassEnabled: boolean;
  rosenpassPermissive: boolean;
  disableIpv6: boolean;
  mtu: number;
  wireguardPort: number;
  customDnsAddress: string;
}

// 仅宿主使用的开关，不进 Core 配置
export interface HostClientSettings {
  autoApplyServerChanges: boolean;
  preferDeviceCodeLogin: boolean;
  autoConnectOnLaunch: boolean;
}

export interface ClientSettings {
  core: CoreClientSettings;
  host: HostClientSettings;
}

export function defaultClientSettings(): ClientSettings {
  return {
    core: {
      manageDns: true,
      acceptRoutes: true,
      blockLanAccess: false,
      blockInbound: false,
      rosenpassEnabled: false,
      rosenpassPermissive: false,
      disableIpv6: false,
      mtu: 0,
      wireguardPort: 0,
      customDnsAddress: ''
    },
    host: {
      autoApplyServerChanges: true,
      preferDeviceCodeLogin: true,
      autoConnectOnLaunch: false
    }
  };
}

function settingsPath(filesDir: string): string {
  return `${filesDir}/${SETTINGS_FILE}`;
}

export function readClientSettings(filesDir: string): ClientSettings {
  const defaults = defaultClientSettings();
  try {
    const path = settingsPath(filesDir);
    if (!fileIo.accessSync(path)) {
      return defaults;
    }
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size = fileIo.statSync(file.fd).size;
      if (size <= 0 || size > 65536) {
        return defaults;
      }
      const buffer = new ArrayBuffer(size);
      const read = fileIo.readSync(file.fd, buffer);
      const text = String.fromCharCode(...new Uint8Array(buffer.slice(0, read)));
      const parsed = JSON.parse(text) as ClientSettings;
      return mergeClientSettings(defaults, parsed);
    } finally {
      fileIo.closeSync(file);
    }
  } catch (_) {
    return defaults;
  }
}

// 逐字段合并，缺失或类型不符的字段回落到默认值，避免旧文件或人工编辑让设置整体失效。
function mergeClientSettings(defaults: ClientSettings, parsed: ClientSettings): ClientSettings {
  const core = parsed.core;
  const host = parsed.host;
  return {
    core: {
      manageDns: typeof core?.manageDns === 'boolean' ? core.manageDns : defaults.core.manageDns,
      acceptRoutes: typeof core?.acceptRoutes === 'boolean' ? core.acceptRoutes : defaults.core.acceptRoutes,
      blockLanAccess: typeof core?.blockLanAccess === 'boolean' ? core.blockLanAccess : defaults.core.blockLanAccess,
      blockInbound: typeof core?.blockInbound === 'boolean' ? core.blockInbound : defaults.core.blockInbound,
      rosenpassEnabled: typeof core?.rosenpassEnabled === 'boolean' ?
        core.rosenpassEnabled : defaults.core.rosenpassEnabled,
      rosenpassPermissive: typeof core?.rosenpassPermissive === 'boolean' ?
        core.rosenpassPermissive : defaults.core.rosenpassPermissive,
      disableIpv6: typeof core?.disableIpv6 === 'boolean' ? core.disableIpv6 : defaults.core.disableIpv6,
      mtu: typeof core?.mtu === 'number' ? core.mtu : defaults.core.mtu,
      wireguardPort: typeof core?.wireguardPort === 'number' ? core.wireguardPort : defaults.core.wireguardPort,
      customDnsAddress: typeof core?.customDnsAddress === 'string' ?
        core.customDnsAddress : defaults.core.customDnsAddress
    },
    host: {
      autoApplyServerChanges: typeof host?.autoApplyServerChanges === 'boolean' ?
        host.autoApplyServerChanges : defaults.host.autoApplyServerChanges,
      preferDeviceCodeLogin: typeof host?.preferDeviceCodeLogin === 'boolean' ?
        host.preferDeviceCodeLogin : defaults.host.preferDeviceCodeLogin,
      autoConnectOnLaunch: typeof host?.autoConnectOnLaunch === 'boolean' ?
        host.autoConnectOnLaunch : defaults.host.autoConnectOnLaunch
    }
  };
}

export function writeClientSettings(filesDir: string, settings: ClientSettings): void {
  const path = settingsPath(filesDir);
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
    fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, JSON.stringify(settings));
    fileIo.fsyncSync(file.fd);
  } finally {
    fileIo.closeSync(file);
  }
}

// Core 只接受它认识的字段，因此单独序列化，避免把宿主开关也传过去被 fail-closed 拒绝。
export function coreSettingsJSON(settings: ClientSettings): string {
  return JSON.stringify(settings.core);
}

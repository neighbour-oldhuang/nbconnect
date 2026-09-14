import { deviceInfo, settings } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

// 注册到管理端的 peer 名称。桌面端上报主机名，鸿蒙上没有免权限就能读到的用户自定义
// 设备名：settings.general.DEVICE_NAME 是出厂派生值（不跟随「设置-关于本机-设备名称」
// 的改名），用户改的那个名字只在 distributedDeviceManager.getLocalDeviceName() 里，
// 而它要 ohos.permission.DISTRIBUTED_DATASYNC（user_grant，需弹窗），不值得为一个
// 节点名去申请。所以按 设备名 → 市场名 → 机型码 逐级降级。
const FALLBACK_DEVICE_NAME = 'nbconnect-vpn';

// settings 和 deviceInfo 的取值都可能抛（键不存在、SA 没起来），逐个兜住。
function readField(read: () => string): string {
  try {
    const value = read();
    return value === undefined || value === null ? '' : value.trim();
  } catch (_) {
    return '';
  }
}

function isHostnameChar(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9');
}

// 管理端按 [^a-zA-Z0-9-]+ → '-' 把 hostname 转成 DNS label，"Pura 80 Pro+" 这种名字
// 会留下 "pura-80-pro-" —— 尾部带横线的非法 label。这里先折叠成主机名风格：
// 连续的非法字符合并成一个 '-'，且不出现在首尾。
function toHostnameLabel(raw: string): string {
  let result = '';
  let pendingSeparator = false;
  for (let i = 0; i < raw.length; i++) {
    const ch = raw.charAt(i);
    if (isHostnameChar(ch)) {
      if (pendingSeparator && result.length > 0) {
        result += '-';
      }
      pendingSeparator = false;
      result += ch;
      continue;
    }
    pendingSeparator = true;
  }
  return result;
}

// Core 注册时上报的 hostname。所有调用 Core 的入口都必须用同一个值：
// 换了值会被管理端判定为 hostname changed，触发 DNS label 变动。
export function deviceDisplayName(context: common.Context): string {
  const settingsName = toHostnameLabel(readField((): string =>
    settings.getValueSync(context, settings.general.DEVICE_NAME, '')));
  if (settingsName.length > 0) {
    return settingsName;
  }
  const marketName = toHostnameLabel(readField((): string => deviceInfo.marketName));
  if (marketName.length > 0) {
    return marketName;
  }
  const productModel = toHostnameLabel(readField((): string => deviceInfo.productModel));
  if (productModel.length > 0) {
    return productModel;
  }
  return FALLBACK_DEVICE_NAME;
}

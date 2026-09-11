import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';

export const NB_BUNDLE_NAME: string = 'org.huangedehw.nbconnect';
export const VPN_COMMAND_EVENT: string = 'org.huangedehw.nbconnect.event.VPN_COMMAND';
export const VPN_STATUS_EVENT: string = 'org.huangedehw.nbconnect.event.VPN_STATUS';
export const VPN_IPC_VERSION: number = 2;

export const KIND_STATUS_REQUEST: string = 'status-request';
export const KIND_STATUS_RESPONSE: string = 'status-response';
export const KIND_CONTROL_REQUEST: string = 'control-request';
export const KIND_CONTROL_RESPONSE: string = 'control-response';
export const KIND_READY: string = 'ready';
// A pending server-side change was applied to the running tunnel, so the host can
// drop the "reconnect to apply" hint and rebase its route comparison.
export const KIND_RECONFIGURED: string = 'reconfigured';
// Platform preparation finished, but the active profile has no usable identity
// yet (no earlier registration and no SSO enrollment), so an explicit connect
// would be rejected with -409.
export const KIND_NEEDS_CREDENTIAL: string = 'needs-credential';
export const KIND_STOPPED: string = 'stopped';
export const KIND_ERROR: string = 'error';
export const KIND_DEBUG_FD_PROBE: string = 'debug-fd-probe';

export const CONTROL_INITIALIZE: string = 'initialize';
export const CONTROL_CONFIGURE: string = 'configure';
export const CONTROL_CONNECT: string = 'connect';
export const CONTROL_DISCONNECT: string = 'disconnect';
export const CONTROL_SHUTDOWN: string = 'shutdown';

export interface VpnIpcPacket {
  version: number;
  kind: string;
  requestId: string;
  payload: string;
}

export interface VpnControlRequest {
  command: string;
}

export interface VpnControlResponse {
  command: string;
  ok: boolean;
  code: number;
  message: string;
  duplicate: boolean;
  lifecycleState: string;
  status: string;
}

export function createVpnIpcPacket(kind: string, requestId: string, payload: string): VpnIpcPacket {
  return {
    version: VPN_IPC_VERSION,
    kind: kind,
    requestId: requestId,
    payload: payload
  };
}

export function createVpnRequestId(): string {
  return `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
}

export function isVpnControlCommand(command: string): boolean {
  return command === CONTROL_INITIALIZE || command === CONTROL_CONFIGURE ||
    command === CONTROL_CONNECT || command === CONTROL_DISCONNECT || command === CONTROL_SHUTDOWN;
}

export function createVpnControlRequest(command: string): VpnControlRequest {
  if (!isVpnControlCommand(command)) {
    throw new Error('unsupported VPN control command');
  }
  return { command: command };
}

export function parseVpnControlRequest(raw: string): VpnControlRequest | undefined {
  try {
    const request = JSON.parse(raw) as VpnControlRequest;
    if (Object.keys(request).length !== 1 || typeof request.command !== 'string' ||
      !isVpnControlCommand(request.command)) {
      return undefined;
    }
    return request;
  } catch (_) {
    return undefined;
  }
}

export function parseVpnControlResponse(raw: string): VpnControlResponse | undefined {
  try {
    const response = JSON.parse(raw) as VpnControlResponse;
    if (!isVpnControlCommand(response.command) || typeof response.ok !== 'boolean' ||
      typeof response.code !== 'number' || typeof response.message !== 'string' ||
      typeof response.duplicate !== 'boolean' || typeof response.lifecycleState !== 'string' ||
      typeof response.status !== 'string') {
      return undefined;
    }
    return response;
  } catch (_) {
    return undefined;
  }
}

export function parseVpnIpcPacket(raw: string): VpnIpcPacket | undefined {
  try {
    const packet = JSON.parse(raw) as VpnIpcPacket;
    if (packet.version !== VPN_IPC_VERSION || typeof packet.kind !== 'string' ||
      typeof packet.requestId !== 'string' || typeof packet.payload !== 'string' ||
      packet.kind.length === 0 || packet.requestId.length === 0) {
      return undefined;
    }
    return packet;
  } catch (_) {
    return undefined;
  }
}

export function runVpnIpcProtocolSelfTest(): string {
  const commands: string[] = [
    CONTROL_INITIALIZE, CONTROL_CONFIGURE, CONTROL_CONNECT, CONTROL_DISCONNECT, CONTROL_SHUTDOWN
  ];
  for (let index = 0; index < commands.length; index++) {
    const request = createVpnControlRequest(commands[index]);
    const parsed = parseVpnControlRequest(JSON.stringify(request));
    if (parsed === undefined || parsed.command !== commands[index]) {
      throw new Error('VPN IPC control command round-trip failed');
    }
  }
  const validResponse = parseVpnControlResponse(
    '{"command":"disconnect","ok":true,"code":0,"message":"","duplicate":false,' +
    '"lifecycleState":"disconnected","status":"{}"}');
  if (validResponse === undefined || validResponse.lifecycleState !== 'disconnected' ||
    parseVpnControlResponse(
      '{"command":"disconnect","ok":true,"code":0,"message":"","duplicate":false,"status":"{}"}') !==
      undefined || parseVpnControlRequest('{"command":"connect","credential":"forbidden"}') !== undefined ||
    parseVpnControlRequest('{"command":"unknown"}') !== undefined ||
    parseVpnIpcPacket('{"version":1,"kind":"control-request","requestId":"old","payload":""}') !== undefined) {
    throw new Error('VPN IPC fail-closed parsing failed');
  }
  return 'VPN IPC v2 control protocol OK';
}

export function createVpnSubscriber(eventName: string): Promise<commonEventManager.CommonEventSubscriber> {
  const info: commonEventManager.CommonEventSubscribeInfo = {
    events: [eventName],
    publisherBundleName: NB_BUNDLE_NAME
  };
  return commonEventManager.createSubscriber(info);
}

export function publishVpnPacket(eventName: string, packet: VpnIpcPacket, code: number): Promise<void> {
  const options: commonEventManager.CommonEventPublishData = {
    bundleName: NB_BUNDLE_NAME,
    code: code,
    data: JSON.stringify(packet)
  };
  return new Promise<void>((resolve, reject) => {
    commonEventManager.publish(eventName, options, (error: BusinessError) => {
      if (error !== null && error.code !== 0) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

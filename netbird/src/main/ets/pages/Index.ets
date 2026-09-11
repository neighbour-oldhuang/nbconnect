import { Want } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { http, socket, vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import netbird from 'libnetbird.so';
import {
  activeProfileId,
  createProfileId,
  credentialImportFileName,
  credentialImportPath,
  legacyProfileCredentialFileName,
  profileConfigPath,
  profileStatePath,
  readProfileIndex,
  VpnProfile,
  VpnProfileIndex,
  writeProfileIndex
} from '../vpn/ProfileStore';
import {
  ClientSettings,
  coreSettingsJSON,
  defaultClientSettings,
  readClientSettings,
  writeClientSettings
} from '../vpn/ClientSettings';
import {
  CONTROL_CONFIGURE,
  CONTROL_CONNECT,
  CONTROL_DISCONNECT,
  CONTROL_INITIALIZE,
  CONTROL_SHUTDOWN,
  createVpnControlRequest,
  createVpnIpcPacket,
  createVpnRequestId,
  createVpnSubscriber,
  KIND_CONTROL_REQUEST,
  KIND_CONTROL_RESPONSE,
  KIND_DEBUG_FD_PROBE,
  KIND_ERROR,
  KIND_NEEDS_CREDENTIAL,
  KIND_READY,
  KIND_RECONFIGURED,
  KIND_STATUS_REQUEST,
  KIND_STATUS_RESPONSE,
  KIND_STOPPED,
  parseVpnControlResponse,
  parseVpnIpcPacket,
  publishVpnPacket,
  VPN_COMMAND_EVENT,
  VPN_STATUS_EVENT,
  VpnControlResponse,
  VpnIpcPacket
} from '../vpn/VpnIpc';

const DOMAIN = 0x4E42;
const DEFAULT_CONFIGURATION_NAME = '我的VPN';
// 左滑操作按钮的单个宽度
const PROFILE_ACTION_WIDTH = 72;
const VPN_WANT: Want = {
  bundleName: 'org.huangedehw.nbconnect',
  abilityName: 'NetbirdVpnExtensionAbility'
};

interface CoreConfigView {
  managementUrl: string;
  adminUrl: string;
  wireGuardInterface: string;
  wireGuardPort: number;
  privateKeyConfigured: boolean;
  disableDns?: boolean;
  disableClientRoutes?: boolean;
}

interface PlatformView {
  configRevision?: number;
  appliedConfigRevision?: number;
  vpnExtensionReady: boolean;
  processProtectReady: boolean;
  tunFdReady: boolean;
  dnsReady: boolean;
  networkChangeReady: boolean;
  lastError?: string;
}

interface RouteDetailView {
  prefix: string;
  via: string;
}

interface PeerDetailView {
  name: string;
  ip: string;
  connectionType: string;
  connected: boolean;
  handshaked: boolean;
}

interface PeerRuntimeView {
  known: number;
  connected: number;
  p2pConnected: number;
  relayedConnected: number;
  withHandshake: number;
  allowedIPs: number;
  routedPeers: number;
  assignedRoutes: number;
  bytesTx: number;
  bytesRx: number;
  details: PeerDetailView[];
}

interface NetworkMapRuntimeView {
  advertisedSyncVersion: number;
  syncVersion: number;
  decodedRoutes: number;
  networkResources: number;
  networkRouters: number;
  resourcePolicies: number;
}


interface ResolvedDomainView {
  domain: string;
  parent?: string;
  addresses: string[];
}

interface SSOFlowView {
  flow: string;
  verificationUriComplete: string;
  verificationUri?: string;
  userCode?: string;
  expiresIn: number;
  interval?: number;
  redirectUrl?: string;
}

interface SSOEnvelope {
  ok: boolean;
  code: number;
  message?: string;
  data?: SSOFlowView;
}

interface AuthenticationView {
  state: string;
  running: boolean;
  configured: boolean;
  persistent: boolean;
  lastError?: string;
}

interface CoreDataView {
  initialized: boolean;
  phase: string;
  clientStatus: string;
  engineRunning: boolean;
  peers: PeerRuntimeView;
  appliedRoutes?: RouteDetailView[];
  resolvedDomains?: ResolvedDomainView[];
  tunnelAddresses?: string[];
  dnsAddresses?: string[];
  preDnsAddress?: string;
  networkMap: NetworkMapRuntimeView;
  platformReady: boolean;
  platform: PlatformView;
  authentication?: AuthenticationView;
  managementConnected?: boolean;
  managementErrorCode?: string;
  signalConnected?: boolean;
  signalErrorCode?: string;
  deviceName: string;
  osName: string;
  osVersion: string;
  netBirdVersion: string;
  netBirdCommit?: string;
  config?: CoreConfigView;
  missingCapabilities?: string[];
}

interface CoreEnvelope {
  ok: boolean;
  code: number;
  message?: string;
  data?: CoreDataView;
}

interface PendingControlRequest {
  command: string;
  timeoutId: number;
  resolve: (response: VpnControlResponse) => void;
  reject: (error: Error) => void;
}

@Entry
@Component
struct Index {
  @State headline: string = '正在初始化本地回归 Core…';
  @State phase: string = '-';
  @State managementUrl: string = '-';
  @State version: string = '-';
  @State details: string = '';
  @State platformDetails: string = 'VPN 进程尚未报告状态';
  @State selfTest: string = '尚未运行';
  @State fdTunSelfTest: string = 'fd TUN adapter 尚未运行';
  @State vpnAction: string = 'IPC 尚未建立';
  @State explicitConnectionState: string = 'unknown';
  @State setupKeyInput: string = '';
  @State privateManagementUrl: string = '';
  @State managementDialAddress: string = '';
  @State credentialAction: string = '尚未导入私有凭据';
  @State e2eTargetUrlInput: string = '';
  @State e2eProbeAction: string = '端到端探测尚未运行';
  @State configurationName: string = 'myvpn';
  // Non-sensitive failure reason reported by the VPN process, and whether Management
  // refused this peer's identity (deleted, ephemeral cleanup, or no auth method).
  @State platformError: string = '';
  @State identityRejected: boolean = false;
  @State configurationNameInput: string = '';
  @State hasConfiguration: boolean = false;
  @State profiles: VpnProfile[] = [];
  @State activeProfile: string = '';
  // 全局客户端设置（对所有服务器配置生效）
  @State settings: ClientSettings = defaultClientSettings();
  @State settingsActive: boolean = false;
  @State settingsMessage: string = '';
  @State editingProfile: string = '';
  // 左滑露出操作按钮的配置项（同一时刻只允许一个展开）
  @State swipedProfile: string = '';
  @State isAddingConfiguration: boolean = false;
  @State vpnPrepared: boolean = false;
  @State extensionStarted: boolean = false;
  @State connectRetryUsed: boolean = false;
  @State connectWhenReady: boolean = false;
  @State peerKnown: number = 0;
  @State peersExpanded: boolean = false;
  @State peerDetails: PeerDetailView[] = [];
  @State appliedRoutes: RouteDetailView[] = [];
  @State resolvedDomains: ResolvedDomainView[] = [];
  @State domainsExpanded: boolean = false;
  @State tunnelAddresses: string[] = [];
  @State dnsAddresses: string[] = [];
  // 由 Core 上报的实际生效状态，用于区分"没接管"和"还没分配"
  @State dnsManagementDisabled: boolean = false;
  @State clientRoutesDisabled: boolean = false;
  @State configRevision: number = 0;
  @State appliedConfigRevision: number = 0;
  @State routeBaseline: string = '';
  @State shimmerOffset: number = -46;
  @State routesExpanded: boolean = false;
  @State peerConnected: number = 0;
  @State peerP2PConnected: number = 0;
  @State peerRelayedConnected: number = 0;
  @State peerHandshake: number = 0;
  @State peerBytesTx: number = 0;
  @State peerBytesRx: number = 0;
  @State routeCount: number = 0;
  private statusSubscriber?: commonEventManager.CommonEventSubscriber;
  // Set while an Extension is deliberately stopped to hand a pending connect a
  // fresh process, so the asynchronous STOPPED packet does not cancel it.
  private restartingForConnect: boolean = false;
  private pendingControls: Map<string, PendingControlRequest> = new Map();
  private statusPollTimer: number = -1;

  aboutToAppear(): void {
    this.initializeLocalCore();
    this.loadProfiles();
    this.loadSettings();
    this.registerVpnStatusSubscriber().then((): void => {
      // The Extension is started on demand by the connect action. Starting an
      // automatic preparation here races with the explicit connect and wastes a
      // full preparation timeout when it loses that race.
      this.maybeAutoConnectOnLaunch();
    }).catch((error: Error) => {
      this.vpnAction = `IPC 订阅失败: ${error.message}`;
      hilog.error(DOMAIN, 'NetBirdVpnIpc', 'VPN_IPC_SUBSCRIBE_FAIL %{public}s', error.message);
    });
  }

  aboutToDisappear(): void {
    this.stopStatusPolling();
    const subscriber = this.statusSubscriber;
    this.statusSubscriber = undefined;
    if (subscriber !== undefined) {
      commonEventManager.unsubscribe(subscriber);
    }
    this.pendingControls.forEach((pending: PendingControlRequest) => clearTimeout(pending.timeoutId));
    this.pendingControls.clear();
  }

  private applyLocalCoreReport(raw: string): void {
    const report = JSON.parse(raw) as CoreEnvelope;
    const data = report.data;
    this.headline = report.ok
      ? `本地回归 Core ${data?.clientStatus ?? 'Ready'}`
      : `本地 Core: ${report.message ?? 'unknown error'}`;
    this.phase = data?.phase ?? '-';
    this.managementUrl = data?.config?.managementUrl ?? '-';
    this.version = data?.netBirdVersion ?? '-';
    const missing = data?.missingCapabilities?.join(', ') ?? '';
    this.details = `initialized=${data?.initialized ?? false}, engine=${data?.engineRunning ?? false}, ` +
      `platformReady=${data?.platformReady ?? false}${missing.length > 0 ? `\n待适配: ${missing}` : ''}`;
  }

  private applyVpnProcessPacket(packet: VpnIpcPacket): void {
    this.extensionStarted = packet.kind !== KIND_STOPPED;
    if (packet.kind === KIND_DEBUG_FD_PROBE) {
      this.runDebugTunTrafficProbe();
      return;
    }
    if (packet.kind === KIND_STOPPED) {
      this.vpnPrepared = false;
      this.resetPeerRuntime();
      this.stopStatusPolling();
      this.platformDetails = '远端 Core 已清除平台状态';
      // A restart for a pending connect stops the old process on purpose. Its
      // STOPPED packet arrives after the shutdown call returned, so cancelling the
      // pending connect here would silently swallow the user's connect request.
      if (this.restartingForConnect) {
        this.explicitConnectionState = 'preparing';
        this.vpnAction = '正在重新准备安全连接…';
        return;
      }
      this.connectWhenReady = false;
      this.explicitConnectionState = 'stopped';
      this.vpnAction = 'VPN 平台进程已停止';
      return;
    }
    if (packet.kind === KIND_CONTROL_RESPONSE) {
      this.applyControlResponse(packet);
      return;
    }
    if (packet.kind === KIND_NEEDS_CREDENTIAL) {
      // The Extension prepared successfully but the active profile has neither a
      // stored identity nor an SSO enrollment path, so a connect would be
      // rejected with -409. Report the missing identity instead of a failure.
      this.vpnPrepared = false;
      this.connectWhenReady = false;
      this.connectRetryUsed = false;
      this.restartingForConnect = false;
      this.stopStatusPolling();
      this.applyRemoteCoreReport(packet.payload, packet.kind);
      this.explicitConnectionState = 'needs-credential';
      // 没有可用身份时直接发起交互式登录，失败再回落到 Setup Key 提示。
      this.startSSOLogin();
      return;
    }
    if (packet.kind === KIND_RECONFIGURED) {
      // The Extension已把服务端变更应用到运行中的隧道，因此重新取基线，
      // 否则"重新连接后生效"的提示会一直挂着，即使变更早就生效了。
      this.applyRemoteCoreReport(packet.payload, packet.kind);
      this.routeBaseline = this.routeSignature();
      this.vpnAction = '服务端配置变更已自动生效';
      hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_IPC_RECONFIGURED_APPLIED');
      return;
    }
    if (packet.kind !== KIND_READY && packet.kind !== KIND_STATUS_RESPONSE && packet.kind !== KIND_ERROR) {
      return;
    }
    if (packet.kind === KIND_READY || packet.kind === KIND_ERROR) {
      // The fresh process reported its outcome, so the restart is over.
      this.restartingForConnect = false;
    }
    // Only an explicit READY means the Extension finished authentication and
    // platform preparation. A status-response can arrive while preparation is
    // still running and must not mark the process as ready to connect.
    if (packet.kind === KIND_READY) {
      this.vpnPrepared = true;
    } else if (packet.kind === KIND_ERROR) {
      this.vpnPrepared = false;
    }
    this.applyRemoteCoreReport(packet.payload, packet.kind);
    if (packet.kind === KIND_ERROR) {
      // Management refused the stored identity, so retrying cannot help. Ask for a
      // new setup key instead of burning another preparation cycle.
      if (this.identityRejected) {
        this.connectWhenReady = false;
        this.stopStatusPolling();
        this.explicitConnectionState = 'needs-credential';
        this.applyMissingCredentialGuidance();
        return;
      }
      // An error while the tunnel was up means the platform was rolled back, most
      // likely by a failed reconfiguration. The engine cannot be prepared twice in
      // one process, so rebuild the connection in a fresh one.
      if (this.isTunnelConnected() && !this.connectRetryUsed) {
        this.connectRetryUsed = true;
        this.explicitConnectionState = 'preparing';
        this.vpnAction = '隧道已被重置，正在自动重新连接…';
        this.restartExtensionAndConnect();
        return;
      }
      // The NetBird engine cannot be restarted inside the same VPN process, so a
      // failed preparation is recovered by restarting the Extension once and
      // connecting again in a fresh process.
      if (this.connectWhenReady && !this.connectRetryUsed) {
        this.connectRetryUsed = true;
        this.connectWhenReady = false;
        this.explicitConnectionState = 'preparing';
        this.vpnAction = '正在重试建立连接…';
        this.restartExtensionAndConnect();
        return;
      }
      this.explicitConnectionState = 'failed';
      this.connectWhenReady = false;
      this.stopStatusPolling();
    } else if (packet.kind === KIND_READY && !this.isTunnelConnected() && !this.isConnectionBusy()) {
      this.explicitConnectionState = 'ready';
    }
    if (packet.kind === KIND_READY && this.connectWhenReady) {
      this.connectWhenReady = false;
      this.requestExplicitConnect().catch((error: Error): void => {
        this.explicitConnectionState = 'failed';
        this.vpnAction = `connect 失败: ${error.message}`;
      });
    }
    hilog.info(DOMAIN, 'NetBirdVpnIpc',
      'VPN_IPC_STATUS_RECEIVED kind=%{public}s request=%{public}s', packet.kind, packet.requestId);
  }

  private applyControlResponse(packet: VpnIpcPacket): void {
    const response = parseVpnControlResponse(packet.payload);
    if (response === undefined) {
      this.vpnAction = '收到无效 control-response';
      return;
    }
    if (response.status.length > 0) {
      this.applyRemoteCoreReport(response.status, KIND_CONTROL_RESPONSE);
    }
    this.explicitConnectionState = response.lifecycleState;
    if (response.lifecycleState === 'connected') {
      this.startStatusPolling();
    } else if (response.lifecycleState === 'disconnected' || response.lifecycleState === 'stopped' ||
      response.lifecycleState === 'failed') {
      this.stopStatusPolling();
      this.resetPeerRuntime();
    }
    const pending = this.pendingControls.get(packet.requestId);
    if (pending === undefined) {
      hilog.warn(DOMAIN, 'NetBirdVpnIpc',
        'VPN_IPC_CONTROL_UNSOLICITED_APPLIED command=%{public}s request=%{public}s',
        response.command, packet.requestId);
      return;
    }
    if (pending.command !== response.command) {
      clearTimeout(pending.timeoutId);
      this.pendingControls.delete(packet.requestId);
      pending.reject(new Error('control-response command mismatch'));
      return;
    }
    clearTimeout(pending.timeoutId);
    this.pendingControls.delete(packet.requestId);
    this.vpnAction = `${response.command} 确认: code=${response.code}, state=${response.lifecycleState}` +
      `${response.duplicate ? '（幂等重放）' : ''}`;
    pending.resolve(response);
    hilog.info(DOMAIN, 'NetBirdVpnIpc',
      'VPN_IPC_CONTROL_CONFIRMED command=%{public}s code=%{public}d duplicate=%{public}s request=%{public}s',
      response.command, response.code, response.duplicate ? 'true' : 'false', packet.requestId);
  }

  private applyRemoteCoreReport(raw: string, kind: string): void {
    try {
      const report = JSON.parse(raw) as CoreEnvelope;
      const data = report.data;
      const platform = data?.platform;
      const peers = data?.peers;
      const networkMap = data?.networkMap;
      if (data?.netBirdVersion !== undefined && data.netBirdVersion.length > 0) {
        this.version = data.netBirdVersion;
      }
      if (data?.config?.privateKeyConfigured === true) {
        this.hasConfiguration = true;
      }
      if (data?.config?.managementUrl !== undefined && data.config.managementUrl.length > 0) {
        this.managementUrl = data.config.managementUrl;
        if (this.privateManagementUrl.length === 0) {
          this.privateManagementUrl = data.config.managementUrl;
        }
      }
      this.peerKnown = peers?.known ?? 0;
      this.peerConnected = peers?.connected ?? 0;
      this.peerP2PConnected = peers?.p2pConnected ?? 0;
      this.peerRelayedConnected = peers?.relayedConnected ?? 0;
      this.peerDetails = (peers?.details ?? []).filter((item: PeerDetailView) => item.connected);
      this.appliedRoutes = (data?.appliedRoutes ?? [])
        .filter((item: RouteDetailView) => !this.isFakeIPRoute(item.prefix));
      this.resolvedDomains = data?.resolvedDomains ?? [];
      this.tunnelAddresses = data?.tunnelAddresses ?? [];
      this.dnsAddresses = data?.dnsAddresses ?? [];
      this.dnsManagementDisabled = data?.config?.disableDns === true;
      this.clientRoutesDisabled = data?.config?.disableClientRoutes === true;
      this.configRevision = platform?.configRevision ?? 0;
      this.appliedConfigRevision = platform?.appliedConfigRevision ?? 0;
      if (this.isTunnelConnected() && this.routeBaseline.length === 0 && this.appliedRoutes.length > 0) {
        this.routeBaseline = this.routeSignature();
      }
      this.peerHandshake = peers?.withHandshake ?? 0;
      this.peerBytesTx = peers?.bytesTx ?? 0;
      this.peerBytesRx = peers?.bytesRx ?? 0;
      this.routeCount = networkMap?.decodedRoutes ?? 0;
      const missing = data?.missingCapabilities?.join(', ') ?? '';
      // Keep the non-sensitive failure reason so the status card can explain a
      // failed connect instead of only saying that the VPN process reported an error.
      this.platformError = (platform?.lastError ?? '').trim();
      const rejectionCode = data?.managementErrorCode ?? '';
      this.identityRejected = this.platformError.includes('identity was rejected by Management') ||
        ((data?.managementConnected !== true) &&
          (rejectionCode === 'PermissionDenied' || rejectionCode === 'Unauthenticated'));
      this.platformDetails = `远端Core=${data?.clientStatus ?? '-'}, extension=${platform?.vpnExtensionReady ?? false}, ` +
        `processProtect=${platform?.processProtectReady ?? false}, tunFd=${platform?.tunFdReady ?? false}, ` +
        `dns=${platform?.dnsReady ?? false}, networkChange=${platform?.networkChangeReady ?? false}` +
        `\n接管DNS=${data?.config?.disableDns === true ? 'false' : 'true'}, ` +
        `接受路由=${data?.config?.disableClientRoutes === true ? 'false' : 'true'}` +
        `\npeers=${peers?.known ?? 0}, connected=${peers?.connected ?? 0}, handshake=${peers?.withHandshake ?? 0}, ` +
        `txActive=${(peers?.bytesTx ?? 0) > 0}, rxActive=${(peers?.bytesRx ?? 0) > 0}` +
        `${missing.length > 0 ? `\n待适配: ${missing}` : ''}` +
        `${platform?.lastError ? `\n错误: ${platform.lastError}` : ''}`;
      if (networkMap !== undefined) {
        hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_CORE_CONFIG disableDns=%{public}s dnsAddresses=%{public}s preDns=%{public}s',
          data?.config?.disableDns === true ? 'true' : 'false',
          (data?.dnsAddresses ?? []).join(','), data?.preDnsAddress ?? '-');
        hilog.info(DOMAIN, 'NetBirdVpnIpc',
          'VPN_NETWORK_MAP_RUNTIME advertisedVersion=%{public}d syncVersion=%{public}d decodedRoutes=%{public}d resources=%{public}d routers=%{public}d policies=%{public}d',
          networkMap.advertisedSyncVersion, networkMap.syncVersion, networkMap.decodedRoutes,
          networkMap.networkResources, networkMap.networkRouters, networkMap.resourcePolicies);
      }
      if (peers !== undefined) {
        hilog.info(DOMAIN, 'NetBirdVpnIpc',
          'VPN_PEER_RUNTIME known=%{public}d connected=%{public}d handshake=%{public}d allowedIPs=%{public}d routedPeers=%{public}d assignedRoutes=%{public}d txActive=%{public}s rxActive=%{public}s',
          peers.known, peers.connected, peers.withHandshake, peers.allowedIPs,
          peers.routedPeers, peers.assignedRoutes,
          peers.bytesTx > 0 ? 'true' : 'false', peers.bytesRx > 0 ? 'true' : 'false');
      }
      if (kind !== KIND_CONTROL_RESPONSE) {
        this.vpnAction = kind === KIND_ERROR
          ? `VPN 进程报告错误${this.platformError.length > 0 ? `: ${this.shortReason(this.platformError)}` : ''}`
          : '已收到 VPN 进程权威状态';
      }
    } catch (error) {
      const err = error as Error;
      this.vpnAction = `远端状态解析失败: ${err.message}`;
    }
  }

  private async runPlainHttpProbe(target: string): Promise<number> {
    const parsed = /^http:\/\/([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(\/[^\s]*)?$/.exec(target);
    if (parsed === null) {
      throw new Error('unsupported HTTP target');
    }
    const host = parsed[1];
    const port = parsed[2] === undefined ? 80 : Number.parseInt(parsed[2], 10);
    const path = parsed[3] === undefined || parsed[3].length === 0 ? '/' : parsed[3];
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error('invalid HTTP port');
    }

    const client = socket.constructTCPSocketInstance();
    try {
      return await new Promise<number>((resolve: (code: number) => void,
        reject: (error: Error) => void): void => {
        let settled = false;
        let responsePrefix = '';
        const timeoutId = setTimeout((): void => {
          if (!settled) {
            settled = true;
            reject(new Error('HTTP response timeout'));
          }
        }, 15000);
        const fail = (error: Error): void => {
          if (!settled) {
            settled = true;
            clearTimeout(timeoutId);
            reject(error);
          }
        };
        client.on('error', (error: BusinessError): void => fail(error));
        client.on('close', (): void => fail(new Error('HTTP socket closed before response')));
        client.on('message', (info: socket.SocketMessageInfo): void => {
          if (settled) {
            return;
          }
          const bytes = new Uint8Array(info.message);
          for (let index = 0; index < bytes.length && responsePrefix.length < 4096; index++) {
            responsePrefix += String.fromCharCode(bytes[index]);
          }
          const lineEnd = responsePrefix.indexOf('\r\n');
          if (lineEnd < 0) {
            if (responsePrefix.length >= 4096) {
              fail(new Error('HTTP status line too long'));
            }
            return;
          }
          const status = /^HTTP\/1\.[01] ([0-9]{3})(?: |$)/.exec(responsePrefix.substring(0, lineEnd));
          if (status === null) {
            fail(new Error('invalid HTTP status line'));
            return;
          }
          const code = Number.parseInt(status[1], 10);
          settled = true;
          clearTimeout(timeoutId);
          resolve(code);
        });
        client.connect({
          address: { address: host, port: port },
          timeout: 15000
        }).then((): Promise<void> => client.send({
          data: `GET ${path} HTTP/1.1\r\nHost: ${host}${port === 80 ? '' : `:${port}`}\r\nConnection: close\r\n\r\n`,
          encoding: 'UTF-8'
        })).catch((error: Error): void => fail(error));
      });
    } finally {
      try {
        await client.close();
      } catch (_) {
      }
    }
  }

  // 交互式登录（SSO）：授权页在应用内的 Web 组件里打开，IdP 重定向到 Core 监听的
  // 本机回调地址即完成，因此不依赖系统浏览器，也不受后台冻结影响。
  @State ssoActive: boolean = false;
  @State ssoAuthUrl: string = '';
  @State ssoUserCode: string = '';
  @State ssoFlow: string = '';
  @State ssoMessage: string = '';
  private ssoPollTimer: number = -1;

  // 设置改动立即落盘，并同步交给本进程的 Core（SSO 登录在 UI 进程完成，也要按设置建 config）。
  private persistSettings(): void {
    try {
      writeClientSettings(this.filesDir(), this.settings);
      const report = JSON.parse(netbird.coreSetClientSettings(coreSettingsJSON(this.settings))) as CoreEnvelope;
      this.settingsMessage = report.ok ? '已保存，重新连接后生效' :
        `设置被拒绝: ${report.message ?? '未知原因'}`;
      hilog.info(DOMAIN, 'NetBirdSettings', 'SETTINGS_SAVED ok=%{public}s', report.ok ? 'true' : 'false');
    } catch (error) {
      const err = error as Error;
      this.settingsMessage = `保存失败: ${err.message}`;
      hilog.error(DOMAIN, 'NetBirdSettings', 'SETTINGS_SAVE_FAIL %{public}s', err.message);
    }
  }

  private loadSettings(): void {
    this.settings = readClientSettings(this.filesDir());
    try {
      netbird.coreSetClientSettings(coreSettingsJSON(this.settings));
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, 'NetBirdSettings', 'SETTINGS_APPLY_FAIL %{public}s', err.message);
    }
  }

  // 数值类设置留空或 0 表示沿用默认，避免用户被迫填一个不知所以的数字。
  private applyNumericSetting(value: string, apply: (parsed: number) => void): void {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      apply(0);
      this.persistSettings();
      return;
    }
    const parsed = Number.parseInt(trimmed, 10);
    if (!Number.isInteger(parsed) || parsed < 0) {
      this.settingsMessage = '请输入非负整数';
      return;
    }
    apply(parsed);
    this.persistSettings();
  }

  // 打开应用即自动连接：仅在本地已有身份时执行，否则会在启动瞬间弹出登录页面。
  private maybeAutoConnectOnLaunch(): void {
    if (!this.settings.host.autoConnectOnLaunch || this.activeProfile.length === 0) {
      return;
    }
    if (!this.hasStoredIdentity(this.activeProfile)) {
      hilog.info(DOMAIN, 'NetBirdVpn', 'AUTO_CONNECT_SKIPPED_NO_IDENTITY');
      return;
    }
    hilog.info(DOMAIN, 'NetBirdVpn', 'AUTO_CONNECT_ON_LAUNCH');
    this.connectWhenReady = true;
    this.explicitConnectionState = 'preparing';
    this.vpnAction = '正在自动连接…';
    this.restartPreparation().catch((error: Error): void => {
      this.connectWhenReady = false;
      this.explicitConnectionState = 'failed';
      this.vpnAction = `自动连接失败: ${error.message}`;
    });
  }

  private hasStoredIdentity(id: string): boolean {
    try {
      return fileIo.accessSync(profileConfigPath(this.filesDir(), id));
    } catch (_) {
      return false;
    }
  }

  private buildSSOConfigPath(): string {
    return profileConfigPath(this.filesDir(), this.activeProfile);
  }

  // 有 setup key 就用 key，没有就走交互式登录；只有在服务端也不支持交互式登录时才提示需要 key。
  private startSSOLogin(): void {
    const management = this.privateManagementUrl.trim();
    if (management.length === 0) {
      this.credentialAction = '请填写管理地址';
      return;
    }
    this.vpnAction = '正在准备登录…';
    try {
      // 登录方式由全局设置决定：设备码把交互整个交给浏览器（企业 SSO 常要跳到另一个应用
      // 再跳回来），PKCE 少一步输码但依赖浏览器能回调到本机监听端口。
      const raw = netbird.coreStartSSOLogin('nbconnect-vpn', 'HarmonyOS',
        this.buildSSOConfigPath(), management, this.settings.host.preferDeviceCodeLogin);
      const envelope = JSON.parse(raw) as SSOEnvelope;
      if (!envelope.ok || envelope.data === undefined ||
        envelope.data.verificationUriComplete.length === 0) {
        throw new Error(envelope.message ?? '无法启动登录');
      }
      this.ssoFlow = envelope.data.flow;
      this.ssoAuthUrl = envelope.data.verificationUriComplete;
      this.ssoUserCode = envelope.data.userCode ?? '';
      this.ssoMessage = this.ssoUserCode.length > 0
        ? '已在浏览器中打开登录页，请确认下方验证码并完成登录'
        : '已在浏览器中打开登录页，请完成登录';
      this.ssoActive = true;
      this.explicitConnectionState = 'preparing';
      this.vpnAction = '等待浏览器中完成登录…';
      this.openSSOAuthPage();
      this.startSSOPolling();
      hilog.info(DOMAIN, 'NetBirdSSO', 'SSO_LOGIN_STARTED flow=%{public}s', this.ssoFlow);
    } catch (error) {
      const err = error as Error;
      this.ssoActive = false;
      this.explicitConnectionState = 'needs-credential';
      this.identityRejected = false;
      this.vpnAction = `登录不可用: ${err.message}，请填写 Setup Key`;
      this.credentialAction = `登录不可用: ${err.message}`;
      hilog.error(DOMAIN, 'NetBirdSSO', 'SSO_LOGIN_START_FAIL %{public}s', err.message);
    }
  }

  private openSSOAuthPage(): void {
    if (this.ssoAuthUrl.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: this.ssoAuthUrl
    };
    context.startAbility(want).then((): void => {
      hilog.info(DOMAIN, 'NetBirdSSO', 'SSO_BROWSER_OPENED');
    }).catch((error: BusinessError): void => {
      this.ssoMessage = `无法打开浏览器（${error.code}），请手动打开下方地址完成登录`;
      hilog.error(DOMAIN, 'NetBirdSSO', 'SSO_BROWSER_OPEN_FAIL code=%{public}d', error.code);
    });
  }

  private startSSOPolling(): void {
    if (this.ssoPollTimer >= 0) {
      return;
    }
    this.ssoPollTimer = setInterval((): void => this.pollSSOState(), 1500);
  }

  private stopSSOPolling(): void {
    if (this.ssoPollTimer < 0) {
      return;
    }
    clearInterval(this.ssoPollTimer);
    this.ssoPollTimer = -1;
  }

  private pollSSOState(): void {
    let state = '';
    let lastError = '';
    try {
      const report = JSON.parse(netbird.coreStatus()) as CoreEnvelope;
      const authentication = report.data?.authentication;
      state = authentication?.state ?? '';
      lastError = authentication?.lastError ?? '';
    } catch (_) {
      return;
    }
    if (state === 'registering') {
      this.ssoMessage = '登录成功，正在注册设备…';
      return;
    }
    if (state === 'configured') {
      this.stopSSOPolling();
      this.ssoActive = false;
      this.hasConfiguration = true;
      this.vpnAction = '登录成功，正在建立连接…';
      this.credentialAction = '已通过交互式登录完成注册';
      hilog.info(DOMAIN, 'NetBirdSSO', 'SSO_LOGIN_CONFIGURED');
      this.connectWhenReady = true;
      this.restartPreparation().catch((error: Error): void => {
        this.explicitConnectionState = 'failed';
        this.vpnAction = `连接失败: ${error.message}`;
      });
      return;
    }
    if (state === 'failed' || state === 'cancelled') {
      this.stopSSOPolling();
      this.ssoActive = false;
      this.explicitConnectionState = state === 'cancelled' ? 'ready' : 'failed';
      const reason = lastError.length > 0 ? this.shortReason(lastError) : '登录未完成';
      this.vpnAction = state === 'cancelled' ? '登录已取消' : `登录失败: ${reason}`;
      this.credentialAction = state === 'cancelled' ? '登录已取消' : `登录失败: ${reason}`;
      hilog.warn(DOMAIN, 'NetBirdSSO', 'SSO_LOGIN_ENDED state=%{public}s', state);
    }
  }

  private cancelSSOLogin(): void {
    this.stopSSOPolling();
    this.ssoActive = false;
    try {
      netbird.coreCancelSSOLogin();
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, 'NetBirdSSO', 'SSO_LOGIN_CANCEL_FAIL %{public}s', err.message);
    }
    this.explicitConnectionState = 'ready';
    this.vpnAction = '登录已取消';
  }

  private async runEndToEndProbe(): Promise<void> {
    const target = this.e2eTargetUrlInput.trim();
    this.e2eTargetUrlInput = '';
    if (target.length === 0 || target.length > 2048 ||
      (!target.startsWith('http://') && !target.startsWith('https://'))) {
      this.e2eProbeAction = '端到端探测目标无效';
      return;
    }
    this.e2eProbeAction = '正在通过 VPN 探测远端服务…';
    try {
      let responseCode = 0;
      if (target.startsWith('http://')) {
        responseCode = await this.runPlainHttpProbe(target);
      } else {
        const request = http.createHttp();
        try {
          const response = await request.request(target, {
            method: http.RequestMethod.GET,
            connectTimeout: 15000,
            readTimeout: 15000
          });
          responseCode = response.responseCode;
        } finally {
          request.destroy();
        }
      }
      if (responseCode < 100 || responseCode > 599) {
        throw new Error('invalid HTTP response code');
      }
      this.e2eProbeAction = `端到端 HTTP 已响应: code=${responseCode}`;
      hilog.info(DOMAIN, 'NetBirdVpnE2E', 'VPN_E2E_HTTP_PROBE_OK code=%{public}d', responseCode);
    } catch (error) {
      const err = error as BusinessError;
      const code = Number.isInteger(err.code) ? err.code : -1;
      this.e2eProbeAction = `端到端 HTTP 探测失败: code=${code}`;
      hilog.error(DOMAIN, 'NetBirdVpnE2E', 'VPN_E2E_HTTP_PROBE_FAIL code=%{public}d', code);
    }
  }

  private runDebugTunTrafficProbe(): void {
    const request = http.createHttp();
    request.request('http://192.0.2.1:9/', {
      method: http.RequestMethod.GET,
      connectTimeout: 1200,
      readTimeout: 1200
    }).then(() => {
      hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_DEBUG_FD_TRAFFIC_PROBE_COMPLETED');
    }).catch(() => {
      // A response is not expected. Emitting the routed SYN is the test.
      hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_DEBUG_FD_TRAFFIC_PROBE_SENT');
    }).finally(() => request.destroy());
  }

  private initializeLocalCore(): void {
    try {
      const report = netbird.coreInit('nbconnect-ui-regression', 'HarmonyOS', '{}');
      this.applyLocalCoreReport(report);
      hilog.info(DOMAIN, 'NetBirdCore', 'CORE_INIT_OK');
    } catch (error) {
      const err = error as Error;
      this.headline = `初始化失败: ${err.message}`;
      hilog.error(DOMAIN, 'NetBirdCore', 'CORE_INIT_FAIL %{public}s', err.message);
    }
  }

  private async registerVpnStatusSubscriber(): Promise<void> {
    this.statusSubscriber = await createVpnSubscriber(VPN_STATUS_EVENT);
    commonEventManager.subscribe(this.statusSubscriber,
      (error: BusinessError, data?: commonEventManager.CommonEventData) => {
        if (error !== null && error.code !== 0) {
          this.vpnAction = `IPC 接收错误: ${error.code}`;
          return;
        }
        if (data?.data === undefined) {
          return;
        }
        const packet = parseVpnIpcPacket(data.data);
        if (packet === undefined) {
          this.vpnAction = '收到无效 VPN IPC 数据';
          return;
        }
        this.applyVpnProcessPacket(packet);
      });
    this.vpnAction = 'IPC 状态订阅已建立';
    hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_IPC_STATUS_SUBSCRIBED');
  }

  private async storePrivateCredentialAndPrepare(): Promise<void> {
    const setupKey = this.setupKeyInput.trim();
    const managementUrl = this.privateManagementUrl.trim();
    this.setupKeyInput = '';
    if (managementUrl.length === 0) {
      this.credentialAction = '请填写管理地址';
      return;
    }
    // Without a setup key there is nothing to import: an already registered peer
    // authenticates with its stored identity, and SSO enrollment supplies no key.
    if (setupKey.length === 0) {
      // Any file still lying around belongs to an earlier attempt, possibly for a
      // different profile, so it must not be consumed by this authentication.
      this.removeStoredFile(credentialImportFileName());
      this.credentialAction = '正在使用已保存的凭据认证';
      await this.restartPreparation();
      return;
    }
    try {
      const credentialPath = credentialImportPath(this.filesDir());
      const result = JSON.parse(netbird.coreStorePrivateCredentialImport(
        credentialPath, setupKey, managementUrl, this.managementDialAddress.trim())) as CoreEnvelope;
      if (!result.ok) {
        throw new Error(result.message ?? '私有凭据导入失败');
      }
      this.credentialAction = '一次性凭据已安全写入，正在启动认证';
      await this.restartPreparation();
    } catch (error) {
      const err = error as Error;
      this.credentialAction = `凭据导入失败: ${err.message}`;
      hilog.error(DOMAIN, 'NetBirdPrivateAuth', 'PRIVATE_CREDENTIAL_IMPORT_FAIL %{public}s', err.message);
    }
  }

  // The NetBird engine cannot be prepared twice inside one VPN process, and
  // starting the ability while the old process is still alive silently reuses it:
  // no preparation runs, the setup key is never consumed and the connect waits
  // for a READY that can no longer arrive. Always hand the authentication a fresh
  // Extension.
  private async restartPreparation(): Promise<void> {
    const connectAfterPrepare = this.connectWhenReady;
    this.restartingForConnect = connectAfterPrepare;
    await this.stopVpnProcess();
    this.vpnPrepared = false;
    this.extensionStarted = false;
    this.connectWhenReady = connectAfterPrepare;
    await this.prepareVpnProcess();
  }

  private async prepareVpnProcess(): Promise<void> {
    try {
      this.vpnAction = '正在启动 VPN Extension…';
      await vpnExtension.startVpnExtensionAbility(VPN_WANT);
      this.vpnAction = 'Extension 已启动，等待远端状态…';
      hilog.info(DOMAIN, 'NetBirdVpn', 'VPN_EXTENSION_START_REQUEST_OK');
      setTimeout(() => this.requestVpnStatus(), 1000);
    } catch (error) {
      const err = error as Error;
      this.vpnAction = `启动失败: ${err.message}`;
      hilog.error(DOMAIN, 'NetBirdVpn', 'VPN_EXTENSION_START_FAIL %{public}s', err.message);
    }
  }

  private resetPeerRuntime(): void {
    this.peerKnown = 0;
    this.peerConnected = 0;
    this.peerP2PConnected = 0;
    this.peerRelayedConnected = 0;
    this.peerHandshake = 0;
    this.peerBytesTx = 0;
    this.peerBytesRx = 0;
    this.routeCount = 0;
    this.peerDetails = [];
    this.appliedRoutes = [];
    this.tunnelAddresses = [];
    this.dnsAddresses = [];
    this.configRevision = 0;
    this.appliedConfigRevision = 0;
    this.routeBaseline = '';
  }

  private startStatusPolling(): void {
    if (this.statusPollTimer >= 0) {
      return;
    }
    this.requestVpnStatus(true);
    this.statusPollTimer = setInterval((): void => {
      this.requestVpnStatus(true);
    }, 2000);
  }

  private stopStatusPolling(): void {
    if (this.statusPollTimer >= 0) {
      clearInterval(this.statusPollTimer);
      this.statusPollTimer = -1;
    }
  }

  private async requestVpnStatus(silent: boolean = false): Promise<void> {
    const requestId = createVpnRequestId();
    const packet = createVpnIpcPacket(KIND_STATUS_REQUEST, requestId, '');
    try {
      await publishVpnPacket(VPN_COMMAND_EVENT, packet, 0);
      if (!silent) {
        this.vpnAction = '正在刷新连接状态…';
      }
      hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_IPC_STATUS_REQUEST_SENT request=%{public}s', requestId);
    } catch (error) {
      const err = error as Error;
      this.vpnAction = `状态请求失败: ${err.message}`;
    }
  }

  private requestVpnControl(command: string, timeoutMs: number = 5000,
    fixedRequestId?: string): Promise<VpnControlResponse> {
    const requestId = fixedRequestId ?? createVpnRequestId();
    const request = createVpnControlRequest(command);
    const packet = createVpnIpcPacket(KIND_CONTROL_REQUEST, requestId, JSON.stringify(request));
    return new Promise<VpnControlResponse>((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        this.pendingControls.delete(requestId);
        reject(new Error(`${command} control request timed out`));
      }, timeoutMs);
      this.pendingControls.set(requestId, {
        command: command,
        timeoutId: timeoutId,
        resolve: resolve,
        reject: reject
      });
      publishVpnPacket(VPN_COMMAND_EVENT, packet, 0).then(() => {
        hilog.info(DOMAIN, 'NetBirdVpnIpc',
          'VPN_IPC_CONTROL_REQUEST_SENT command=%{public}s request=%{public}s', command, requestId);
      }).catch((error: Error) => {
        const pending = this.pendingControls.get(requestId);
        if (pending !== undefined) {
          clearTimeout(pending.timeoutId);
          this.pendingControls.delete(requestId);
          pending.reject(error);
        }
      });
    });
  }

  private async runVpnControl(command: string): Promise<void> {
    const connecting = command === CONTROL_CONNECT;
    const disconnecting = command === CONTROL_DISCONNECT;
    if (connecting) {
      this.resetPeerRuntime();
      this.explicitConnectionState = 'connecting';
      this.vpnAction = '正在创建系统隧道…';
      this.startStatusPolling();
    } else if (disconnecting) {
      this.explicitConnectionState = 'disconnecting';
      this.vpnAction = '正在断开并释放网络资源…';
    }
    try {
      const response = await this.requestVpnControl(command, connecting ? 90000 : 30000);
      if (!response.ok) {
        throw new Error(`${response.message} (${response.code})`);
      }
      if (connecting) {
        this.vpnAction = this.isPeerVerified() ? '连接已验证' : '系统隧道已建立，正在等待节点握手';
        this.startStatusPolling();
      } else if (disconnecting) {
        this.vpnAction = '连接已断开';
        this.stopStatusPolling();
        this.resetPeerRuntime();
        // The NetBird engine cannot be restarted inside the same VPN process: a
        // second run returns without waiting for a tunnel fd. Stop the Extension
        // so the next connect starts from a fresh, reconnectable core.
        await this.stopVpnProcess();
        this.vpnPrepared = false;
        this.extensionStarted = false;
        this.connectWhenReady = false;
        this.explicitConnectionState = 'disconnected';
        this.vpnAction = '连接已断开';
      }
    } catch (error) {
      const err = error as Error;
      if (connecting && err.message.includes('cannot start from preparing')) {
        // The Extension is still authenticating and preparing. Wait for READY and
        // connect automatically instead of reporting a failure to the user.
        this.connectWhenReady = true;
        this.explicitConnectionState = 'preparing';
        this.vpnAction = '正在认证并准备网络配置…';
        return;
      }
      if (connecting && err.message.includes('private preparation is not ready')) {
        // Neither a stored identity nor SSO is available for this profile, so no
        // retry can succeed until a setup key is imported.
        this.connectWhenReady = false;
        this.vpnPrepared = false;
        this.stopStatusPolling();
        this.explicitConnectionState = 'needs-credential';
        this.applyMissingCredentialGuidance();
        return;
      }
      if (connecting && err.message.includes('lease changed before consumption') &&
        !this.connectRetryUsed) {
        // The desired configuration moved while the tunnel was being created, so it
        // has to be rebuilt from the newer revision. The engine cannot be prepared
        // twice in one process, hence the restart.
        this.connectRetryUsed = true;
        this.connectWhenReady = false;
        this.explicitConnectionState = 'preparing';
        this.vpnAction = '网络配置已刷新，正在重新建立连接…';
        this.restartExtensionAndConnect();
        return;
      }
      this.explicitConnectionState = 'failed';
      this.stopStatusPolling();
      this.vpnAction = `${connecting ? '连接' : disconnecting ? '断开' : command}失败: ${err.message}`;
    }
  }

  private async verifyControlIdempotency(): Promise<void> {
    const requestId = createVpnRequestId();
    try {
      const first = await this.requestVpnControl(CONTROL_INITIALIZE, 5000, requestId);
      const second = await this.requestVpnControl(CONTROL_INITIALIZE, 5000, requestId);
      if (!first.ok || first.duplicate || !second.ok || !second.duplicate || first.code !== second.code) {
        throw new Error('control idempotency contract failed');
      }
      this.vpnAction = 'initialize requestId 幂等重放通过';
      hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_IPC_IDEMPOTENCY_OK');
    } catch (error) {
      const err = error as Error;
      this.vpnAction = `IPC 幂等自检失败: ${err.message}`;
    }
  }

  private restartExtensionAndConnect(): void {
    this.restartingForConnect = true;
    this.stopVpnProcess().then((): Promise<void> => {
      this.vpnPrepared = false;
      this.extensionStarted = false;
      this.connectWhenReady = true;
      this.explicitConnectionState = 'preparing';
      this.vpnAction = '正在重新准备安全连接…';
      return this.prepareVpnProcess();
    }).catch((error: Error): void => {
      this.restartingForConnect = false;
      this.connectWhenReady = false;
      this.explicitConnectionState = 'failed';
      this.vpnAction = `连接失败: ${error.message}`;
    });
  }

  private async requestExplicitConnect(): Promise<void> {
    await this.runVpnControl(CONTROL_CONNECT);
  }

  private async requestExplicitDisconnect(): Promise<void> {
    await this.runVpnControl(CONTROL_DISCONNECT);
  }

  private isTunnelConnected(): boolean {
    return this.explicitConnectionState === 'connected';
  }

  private isConnectionBusy(): boolean {
    return this.explicitConnectionState === 'preparing' || this.explicitConnectionState === 'connecting' ||
      this.explicitConnectionState === 'disconnecting';
  }

  // The setup key is optional in general: a peer that already registered reuses
  // its stored identity, and SSO enrollment needs no key. This state is only
  // reached when neither exists — no stored identity and no SSO support yet — so
  // the only way forward today is a setup key.
  private applyMissingCredentialGuidance(): void {
    if (this.identityRejected) {
      // The identity exists locally but Management refused it: the peer was removed
      // server-side (an ephemeral setup key cleans peers up once they go offline) or
      // it needs a fresh enrollment.
      this.vpnAction = '服务端已拒绝该身份（peer 可能已被删除或由临时 Setup Key 注册），请填写新的 Setup Key 重新注册';
      this.credentialAction = '服务端不再认识此身份，请填写新的 Setup Key 重新注册';
      hilog.warn(DOMAIN, 'NetBirdPrivateAuth', 'PRIVATE_IDENTITY_REJECTED_BY_MANAGEMENT');
      return;
    }
    this.vpnAction = '该配置没有可用身份：未找到已保存的凭据，SSO 登录暂未支持，请填写 Setup Key 后再次点击连接';
    this.credentialAction = '未找到已保存的凭据（SSO 暂未支持），请填写 Setup Key 后再次点击连接';
    hilog.warn(DOMAIN, 'NetBirdPrivateAuth', 'PRIVATE_IDENTITY_MISSING_NO_SSO');
  }

  // Error strings carry appended diagnostics; keep the status card readable.
  private shortReason(reason: string): string {
    const trimmed = reason.trim();
    return trimmed.length > 160 ? `${trimmed.substring(0, 160)}…` : trimmed;
  }

  private isPeerVerified(): boolean {
    return this.isTunnelConnected() && this.peerConnected > 0 && this.peerHandshake > 0;
  }

  private showConnectionPanel(): boolean {
    return this.isTunnelConnected() || this.isConnectionBusy();
  }

  private statusTitle(): string {
    if (this.explicitConnectionState === 'preparing') {
      return '正在准备';
    }
    if (this.explicitConnectionState === 'connecting') {
      return '正在连接';
    }
    if (this.explicitConnectionState === 'disconnecting') {
      return '正在断开';
    }
    // Per-peer connection types live in the Peers list; a single aggregated label
    // here was redundant and misleading for mixed paths.
    if (this.isPeerVerified()) {
      return 'VPN 已连接';
    }
    if (this.isTunnelConnected()) {
      return '正在连接节点';
    }
    if (this.explicitConnectionState === 'failed') {
      return '连接失败';
    }
    if (this.explicitConnectionState === 'needs-credential') {
      return '需要凭据';
    }
    return '未连接';
  }

  private statusSubtitle(): string {
    if (this.explicitConnectionState === 'preparing') {
      return '正在认证并准备网络配置…';
    }
    if (this.explicitConnectionState === 'connecting') {
      return '正在创建系统隧道并启动 WireGuard…';
    }
    if (this.explicitConnectionState === 'disconnecting') {
      return '正在停止隧道并释放网络资源…';
    }
    if (this.isPeerVerified()) {
      return `WireGuard 已握手 · ${this.peerConnected} 个节点在线`;
    }
    if (this.isTunnelConnected()) {
      return '系统隧道已建立 · 正在等待节点握手';
    }
    if (this.explicitConnectionState === 'failed') {
      return this.platformError.length > 0 ? this.shortReason(this.platformError) :
        '连接未建立，可再次点击连接重试';
    }
    if (this.explicitConnectionState === 'needs-credential') {
      return this.identityRejected ? '服务端不再认识此身份，请填写新的 Setup Key 重新注册' :
        '未找到已保存的凭据（SSO 暂未支持），请填写 Setup Key 后再次点击连接';
    }
    return '';
  }

  private statusColor(): Resource {
    if (this.isPeerVerified()) {
      return $r('app.color.nb_status_connected');
    }
    if (this.showConnectionPanel()) {
      return $r('app.color.nb_status_progress');
    }
    if (this.explicitConnectionState === 'failed') {
      return $r('app.color.nb_status_failed');
    }
    return $r('app.color.nb_status_idle');
  }

  // The desired config revision advances once right after connect when the engine
  // applies its initial routes, so it cannot signal a server change on its own.
  // Comparing the route set against the one captured at connect time can.
  private routeSignature(): string {
    return this.appliedRoutes.map((item: RouteDetailView) => item.prefix).sort().join(',');
  }

  // Domain resources are reached through addresses the Core allocates from its
  // reserved fake IP blocks and translates back internally. They are an
  // implementation detail: showing them as routes is noise, and counting them as a
  // configuration change turns every new domain lookup into a false "server config
  // changed" hint.
  private isFakeIPRoute(prefix: string): boolean {
    return prefix.startsWith('240.') || prefix.toLowerCase().startsWith('100:');
  }

  private hasPendingConfiguration(): boolean {
    return this.isTunnelConnected() && this.routeBaseline.length > 0 &&
      this.routeSignature() !== this.routeBaseline;
  }

  // A slow, endless sheen across the platform badge. Kept linear and low-opacity
  // so it reads as ambient light rather than a progress indicator. The offset is
  // reset first: animating to a value it already holds produces no motion.
  private startShimmer(): void {
    this.shimmerOffset = -46;
    setTimeout((): void => {
      animateTo({
        duration: 2800,
        curve: Curve.Linear,
        delay: 400,
        iterations: -1,
        playMode: PlayMode.Normal
      }, () => {
        this.shimmerOffset = 132;
      });
    }, 60);
  }

  // 关掉"接管系统 DNS"时不是"还没分配"，而是按设置根本不去接管，两者要分开表述。
  private dnsAddressLabel(): string {
    if (this.dnsAddresses.length > 0) {
      return this.dnsAddresses.join(' · ');
    }
    return this.dnsManagementDisabled ? '未接管（设置已关闭）' : '未分配';
  }

  private tunnelAddressLabel(): string {
    if (this.tunnelAddresses.length === 0) {
      return this.isPeerVerified() ? '正在获取' : '未分配';
    }
    const ipv4 = this.tunnelAddresses.find((item: string) => !item.includes(':'));
    return ipv4 !== undefined ? ipv4 : this.tunnelAddresses[0];
  }

  private primaryActionLabel(): string {
    // Preparation can run for a minute, so the button stays actionable and offers
    // to abort instead of showing a dead progress label.
    if (this.explicitConnectionState === 'preparing' || this.explicitConnectionState === 'connecting') {
      return '取消';
    }
    if (this.explicitConnectionState === 'disconnecting') {
      return '正在断开…';
    }
    return this.isTunnelConnected() ? '断开连接' : '连接';
  }

  private displayVersion(): string {
    if (this.version.length === 0 || this.version === '-' || this.version.includes('development')) {
      return 'HarmonyOS';
    }
    const normalized = this.version.startsWith('v') ? this.version : `v${this.version}`;
    return normalized.endsWith('-ohos') ? normalized : `${normalized}-ohos`;
  }

  private displayManagementAddress(): string {
    const value = this.privateManagementUrl.trim();
    return value.length > 0 ? value : 'Management 配置已安全保存';
  }

  private statusNotice(): string {
    // Any actionable credential message must surface; otherwise a rejected save
    // looks like the button did nothing.
    if (this.credentialAction.includes('失败') || this.credentialAction.startsWith('请') ||
      this.credentialAction.includes('已清除') || this.credentialAction.includes('已删除')) {
      return this.credentialAction;
    }
    if (this.vpnAction.includes('失败') || this.vpnAction.includes('错误') ||
      this.vpnAction.includes('超时')) {
      return this.vpnAction;
    }
    if (this.showConnectionPanel()) {
      return '';
    }
    if (this.vpnAction.includes('正在') || this.credentialAction.includes('正在')) {
      return this.vpnAction.includes('正在') ? this.vpnAction : this.credentialAction;
    }
    return '';
  }

  // A single persisted profile is supported, so adding starts from an empty form
  // and saving replaces the stored configuration.
  private beginAddConfiguration(): void {
    this.configurationNameInput = DEFAULT_CONFIGURATION_NAME;
    this.privateManagementUrl = '';
    this.setupKeyInput = '';
    this.isAddingConfiguration = true;
    this.credentialAction = '';
  }

  private cancelAddConfiguration(): void {
    this.isAddingConfiguration = false;
    this.configurationNameInput = '';
  }

  private async saveConfiguration(connectAfterSave: boolean = false): Promise<void> {
    const management = this.privateManagementUrl.trim();
    if (management.length === 0) {
      this.credentialAction = '请填写管理地址';
      return;
    }
    if (this.isTunnelConnected() || this.isConnectionBusy()) {
      this.credentialAction = '请先断开连接再修改配置';
      return;
    }
    // The setup key is optional: an already registered peer reuses its stored
    // identity, and SSO enrollment will not provide a key at all.
    const name = this.configurationNameInput.trim();
    const resolvedName = name.length > 0 ? name : DEFAULT_CONFIGURATION_NAME;
    // Saving from the connect action must update the selected configuration. Only
    // the explicit "add" form creates a new one: falling through to the create
    // branch produced a duplicate profile with its own empty identity, which then
    // failed to connect because the setup key registered the new profile instead.
    const targetId = this.editingProfile.length > 0 ? this.editingProfile :
      (this.isAddingConfiguration ? '' : this.activeProfile);
    const existing = targetId.length > 0 ?
      this.profiles.find((item: VpnProfile) => item.id === targetId) : undefined;
    if (existing !== undefined) {
      existing.name = resolvedName;
      existing.managementUrl = management;
      this.profiles = this.profiles.map((item: VpnProfile) => item.id === existing.id ? existing : item);
      this.activeProfile = existing.id;
    } else {
      const created: VpnProfile = {
        id: createProfileId(),
        name: resolvedName,
        managementUrl: management
      };
      this.profiles = this.profiles.concat([created]);
      this.activeProfile = created.id;
    }
    this.editingProfile = '';
    this.configurationName = resolvedName;
    this.hasConfiguration = true;
    this.isAddingConfiguration = false;
    this.connectWhenReady = connectAfterSave;
    this.persistProfiles();
    await this.storePrivateCredentialAndPrepare();
  }

  // Aborts an in-flight preparation or connect attempt and returns to idle.
  private async cancelConnectionAttempt(): Promise<void> {
    this.connectWhenReady = false;
    this.restartingForConnect = false;
    this.connectRetryUsed = false;
    this.stopStatusPolling();
    this.vpnAction = '正在取消…';
    await this.stopVpnProcess();
    this.vpnPrepared = false;
    this.extensionStarted = false;
    this.explicitConnectionState = 'unknown';
    this.resetPeerRuntime();
    this.vpnAction = '已取消连接';
    hilog.info(DOMAIN, 'NetBirdVpn', 'CONNECT_ATTEMPT_CANCELLED');
  }

  private async handlePrimaryAction(): Promise<void> {
    if (this.explicitConnectionState === 'preparing' || this.explicitConnectionState === 'connecting') {
      await this.cancelConnectionAttempt();
      return;
    }
    if (this.isConnectionBusy()) {
      this.vpnAction = this.statusSubtitle();
      return;
    }
    if (this.isTunnelConnected()) {
      await this.requestExplicitDisconnect();
      return;
    }
    if (!this.hasConfiguration) {
      this.beginAddConfiguration();
      return;
    }
    this.connectRetryUsed = false;
    this.platformError = '';
    this.identityRejected = false;
    if (this.setupKeyInput.trim().length > 0) {
      this.configurationNameInput = this.configurationName;
      await this.saveConfiguration(true);
      return;
    }
    // 该配置没有可用身份：优先尝试交互式登录，只有服务端也不支持时才要求 Setup Key。
    if (this.explicitConnectionState === 'needs-credential') {
      this.startSSOLogin();
      return;
    }
    // A connect is only accepted by the Extension once preparation finished and
    // it reported READY (privateConfigured + platform adapter created). Sending
    // CONNECT while the process is merely started but not yet prepared returns
    // "-409 VPN private preparation is not ready". So connect immediately only
    // when prepared; otherwise (re)prepare and connect automatically on READY.
    if (this.vpnPrepared) {
      await this.requestExplicitConnect();
      return;
    }
    this.connectWhenReady = true;
    this.explicitConnectionState = 'preparing';
    this.vpnAction = '正在准备安全连接…';
    if (this.extensionStarted) {
      // The process is alive but its previous preparation did not complete. It
      // cannot re-run the NetBird engine in the same process, so restart the
      // Extension to get a fresh, connectable core.
      this.restartExtensionAndConnect();
      return;
    }
    await this.prepareVpnProcess();
  }

  private filesDir(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return context.getApplicationContext().filesDir;
  }

  // Loads the profile list and migrates a pre-existing single configuration so an
  // upgrade keeps working without re-entering the setup key.
  private loadProfiles(): void {
    try {
      const dir = this.filesDir();
      let index = readProfileIndex(dir);
      if (index.profiles.length === 0 && fileIo.accessSync(`${dir}/netbird-private.json`)) {
        const migrated: VpnProfile = {
          id: 'default',
          name: this.configurationName,
          managementUrl: ''
        };
        // The setup key transfer file keeps its original fixed name: the Core only
        // accepts that basename, so renaming it per profile made it unusable.
        for (const name of ['netbird-private', 'netbird-state']) {
          const from = `${dir}/${name}.json`;
          if (fileIo.accessSync(from)) {
            fileIo.moveFileSync(from, `${dir}/${name}-default.json`);
          }
        }
        index = { activeId: 'default', profiles: [migrated] };
        writeProfileIndex(dir, index);
        hilog.info(DOMAIN, 'NetBirdProfile', 'PROFILE_MIGRATED_TO_LIST');
      }
      this.applyProfileIndex(index);
      this.purgeStaleCredentialImports(index);
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, 'NetBirdProfile', 'PROFILE_LOAD_FAIL %{public}s', err.message);
      this.profiles = [];
      this.activeProfile = '';
      this.hasConfiguration = false;
    }
  }

  // A pending setup key transfer belongs to the profile it was typed for. The
  // Core deletes it when it starts authenticating, so a file that survives an app
  // restart is a leftover from a failed attempt and must not register a different
  // profile later. Unusable per-profile files from earlier builds go with it.
  private purgeStaleCredentialImports(index: VpnProfileIndex): void {
    this.removeStoredFile(credentialImportFileName());
    for (const profile of index.profiles) {
      this.removeStoredFile(legacyProfileCredentialFileName(profile.id));
    }
  }

  private applyProfileIndex(index: VpnProfileIndex): void {
    this.profiles = index.profiles;
    this.activeProfile = index.activeId.length > 0 ? index.activeId :
      (index.profiles.length > 0 ? index.profiles[0].id : '');
    this.hasConfiguration = index.profiles.length > 0;
    const active = index.profiles.find((item: VpnProfile) => item.id === this.activeProfile);
    if (active !== undefined) {
      this.configurationName = active.name;
      this.privateManagementUrl = active.managementUrl;
    }
  }

  private persistProfiles(): void {
    try {
      writeProfileIndex(this.filesDir(), { activeId: this.activeProfile, profiles: this.profiles });
    } catch (error) {
      const err = error as Error;
      this.credentialAction = `保存配置列表失败: ${err.message}`;
    }
  }

  // Switching profiles must stop the current VPN process so the next connect
  // authenticates with the selected profile's own identity files.
  private selectProfile(id: string): void {
    if (id === this.activeProfile) {
      return;
    }
    if (this.isTunnelConnected() || this.isConnectionBusy()) {
      this.credentialAction = '请先断开连接再切换配置';
      return;
    }
    this.stopVpnProcess().then((): void => {
      // The shared transfer file must not carry a key typed for the old profile
      // into the newly selected one.
      this.removeStoredFile(credentialImportFileName());
      this.activeProfile = id;
      const selected = this.profiles.find((item: VpnProfile) => item.id === id);
      if (selected !== undefined) {
        this.configurationName = selected.name;
        this.privateManagementUrl = selected.managementUrl;
      }
      this.setupKeyInput = '';
      this.vpnPrepared = false;
      this.extensionStarted = false;
      this.explicitConnectionState = 'unknown';
      this.resetPeerRuntime();
      this.persistProfiles();
      this.credentialAction = `已切换到 ${this.configurationName}`;
      hilog.info(DOMAIN, 'NetBirdProfile', 'PROFILE_SWITCHED');
    }).catch((error: Error): void => {
      this.credentialAction = `切换配置失败: ${error.message}`;
    });
  }

  private removeStoredFile(name: string): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path = `${context.getApplicationContext().filesDir}/${name}`;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, 'NetBirdPrivateAuth', 'CREDENTIAL_FILE_REMOVE_FAIL %{public}s', err.message);
    }
  }

  // 重置与删除都会丢弃本地身份且不可撤销，先让用户确认。
  private confirmResetProfile(item: VpnProfile): void {
    this.closeProfileActions();
    if (this.isTunnelConnected() || this.isConnectionBusy()) {
      this.credentialAction = '请先断开连接再重置';
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '重置登录状态',
      message: `将清除「${item.name}」的本地身份（私钥与注册状态），下次连接需要重新认证。配置名称与管理地址会保留。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '重置',
        fontColor: $r('app.color.nb_status_progress'),
        action: (): void => this.resetProfileIdentity(item.id)
      }
    });
  }

  private confirmDeleteProfile(item: VpnProfile): void {
    this.closeProfileActions();
    if (this.isTunnelConnected() || this.isConnectionBusy()) {
      this.credentialAction = '请先断开连接再删除配置';
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除配置',
      message: `将删除「${item.name}」及其本地身份文件，此操作不可撤销。服务端上的设备记录需要在管理端自行清理。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.nb_status_failed'),
        action: (): void => this.deleteConfiguration(item.id)
      }
    });
  }

  // 滑开时卡片右侧收掉圆角和描边，与按钮拼成一条连续的胶囊，不再出现圆角撞直角的断裂感。
  private profileCardRadius(id: string): BorderRadiuses {
    const swiped = this.swipedProfile === id;
    return {
      topLeft: 18,
      bottomLeft: 18,
      topRight: swiped ? 0 : 18,
      bottomRight: swiped ? 0 : 18
    };
  }

  private profileCardBorderWidth(id: string): EdgeWidths {
    return { left: 1, top: 1, bottom: 1, right: this.swipedProfile === id ? 0 : 1 };
  }

  private openProfileActions(id: string): void {
    if (this.swipedProfile === id) {
      return;
    }
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.swipedProfile = id;
    });
  }

  private closeProfileActions(): void {
    if (this.swipedProfile.length === 0) {
      return;
    }
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.swipedProfile = '';
    });
  }

  // 编辑：复用添加配置的表单，只是带上目标配置的现有值，保存时按 editingProfile 更新。
  private beginEditConfiguration(item: VpnProfile): void {
    this.closeProfileActions();
    if (this.isTunnelConnected() || this.isConnectionBusy()) {
      this.credentialAction = '请先断开连接再修改配置';
      return;
    }
    this.editingProfile = item.id;
    this.configurationNameInput = item.name;
    this.privateManagementUrl = item.managementUrl;
    this.setupKeyInput = '';
    this.isAddingConfiguration = true;
    this.credentialAction = '';
  }

  // 重置：清掉该配置的身份（config + 私钥、注册状态、待导入的一次性 key），
  // 只保留名称和管理地址。之前只删注册状态时本地私钥仍在，扩展会直接恢复身份连上，
  // 看起来像是"重置了却还登录着"。
  private resetProfileIdentity(id: string): void {
    this.closeProfileActions();
    if (this.isTunnelConnected() || this.isConnectionBusy()) {
      this.credentialAction = '请先断开连接再重置';
      return;
    }
    this.stopVpnProcess().then((): void => {
      this.removeStoredFile(`netbird-private-${id}.json`);
      this.removeStoredFile(`netbird-state-${id}.json`);
      this.removeStoredFile(credentialImportFileName());
      this.removeStoredFile(legacyProfileCredentialFileName(id));
      this.setupKeyInput = '';
      this.vpnPrepared = false;
      this.extensionStarted = false;
      this.explicitConnectionState = 'unknown';
      this.identityRejected = false;
      this.platformError = '';
      this.resetPeerRuntime();
      this.credentialAction = '已重置该配置的登录状态，下次连接将重新认证';
      this.vpnAction = '已重置登录状态';
      hilog.info(DOMAIN, 'NetBirdPrivateAuth', 'IDENTITY_CLEARED');
    }).catch((error: Error): void => {
      this.credentialAction = `重置失败: ${error.message}`;
    });
  }

  // Removes one configuration together with its own credential material.
  private deleteConfiguration(id: string): void {
    if (this.isTunnelConnected() || this.isConnectionBusy()) {
      this.credentialAction = '请先断开连接再删除配置';
      return;
    }
    this.stopVpnProcess().then((): void => {
      this.removeStoredFile(`netbird-private-${id}.json`);
      this.removeStoredFile(`netbird-state-${id}.json`);
      this.removeStoredFile(credentialImportFileName());
      this.removeStoredFile(legacyProfileCredentialFileName(id));
      this.profiles = this.profiles.filter((item: VpnProfile) => item.id !== id);
      if (this.activeProfile === id) {
        this.activeProfile = this.profiles.length > 0 ? this.profiles[0].id : '';
        const next = this.profiles.find((item: VpnProfile) => item.id === this.activeProfile);
        this.configurationName = next !== undefined ? next.name : DEFAULT_CONFIGURATION_NAME;
        this.privateManagementUrl = next !== undefined ? next.managementUrl : '';
      }
      this.hasConfiguration = this.profiles.length > 0;
      this.isAddingConfiguration = false;
      this.setupKeyInput = '';
      this.vpnPrepared = false;
      this.extensionStarted = false;
      this.explicitConnectionState = 'unknown';
      this.resetPeerRuntime();
      this.persistProfiles();
      this.credentialAction = '配置已删除';
      hilog.info(DOMAIN, 'NetBirdPrivateAuth', 'CONFIGURATION_DELETED');
    }).catch((error: Error): void => {
      this.credentialAction = `删除配置失败: ${error.message}`;
    });
  }

  private async stopVpnProcess(): Promise<void> {
    // When no Extension is running there is no IPC responder, so the shutdown
    // control request would block for its full timeout before rejecting. Skip
    // the round-trip entirely in that case to keep profile switching instant.
    if (!this.extensionStarted && !this.vpnPrepared) {
      hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_IPC_SHUTDOWN_SKIPPED_NOT_RUNNING');
      return;
    }
    try {
      const response = await this.requestVpnControl(CONTROL_SHUTDOWN, 7000);
      if (!response.ok || response.code !== 0) {
        throw new Error(`${response.message} (${response.code})`);
      }
      hilog.info(DOMAIN, 'NetBirdVpnIpc', 'VPN_IPC_SHUTDOWN_CONFIRMED');
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, 'NetBirdVpnIpc', 'VPN_IPC_SHUTDOWN_CONFIRM_FAIL %{public}s', err.message);
    }
    try {
      await vpnExtension.stopVpnExtensionAbility(VPN_WANT);
      this.vpnAction = 'VPN Extension 已停止';
      this.platformDetails = 'VPN 进程已停止；未建立 TUN';
      hilog.info(DOMAIN, 'NetBirdVpn', 'VPN_EXTENSION_STOP_OK');
    } catch (error) {
      const err = error as Error;
      this.vpnAction = `停止失败: ${err.message}`;
      hilog.error(DOMAIN, 'NetBirdVpn', 'VPN_EXTENSION_STOP_FAIL %{public}s', err.message);
    }
  }

  private tryConnectBoundary(): void {
    try {
      const report = netbird.coreConnect();
      this.applyLocalCoreReport(report);
      hilog.info(DOMAIN, 'NetBirdCore', 'CORE_CONNECT %{public}s', report);
    } catch (error) {
      const err = error as Error;
      this.headline = `连接调用失败: ${err.message}`;
    }
  }

  private runFDTunSelfTest(): void {
    try {
      const report = netbird.coreTunSelfTest();
      this.fdTunSelfTest = report;
      hilog.info(DOMAIN, 'GoVerify', 'FDTUN_SELFTEST %{public}s', report);
    } catch (error) {
      const err = error as Error;
      this.fdTunSelfTest = `ERROR: ${err.message}`;
      hilog.error(DOMAIN, 'GoVerify', 'FDTUN_SELFTEST_FAIL %{public}s', err.message);
    }
  }

  private runSelfTest(): void {
    try {
      const report = netbird.coreSelfTest();
      this.selfTest = report;
      hilog.info(DOMAIN, 'GoVerify', 'GO_RUNTIME_OK %{public}s', report);
    } catch (error) {
      const err = error as Error;
      this.selfTest = `ERROR: ${err.message}`;
      hilog.error(DOMAIN, 'GoVerify', 'GO_RUNTIME_FAIL %{public}s', err.message);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Text('NBConnect')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.nb_text_primary'))
            Text('设置')
              .fontSize(13)
              .fontColor($r('app.color.nb_accent'))
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .onClick(() => {
                this.settingsMessage = '';
                this.settingsActive = true;
              })
            Blank()
            Stack({ alignContent: Alignment.Start }) {
              // Slightly taller than the title cap height for a balanced pill, with
              // tighter horizontal padding.
              Text(this.displayVersion())
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isTunnelConnected() ? $r('app.color.nb_on_accent') :
                  $r('app.color.nb_text_tertiary'))
                .height(19)
                .textAlign(TextAlign.Center)
                .padding({ left: 9, right: 9 })
              if (this.isTunnelConnected()) {
                Row()
                  .width(30)
                  .height(19)
                  .linearGradient({
                    angle: 115,
                    colors: [['#00FFFFFF', 0.0], ['#73FFFFFF', 0.5], ['#00FFFFFF', 1.0]]
                  })
                  .translate({ x: this.shimmerOffset })
                  .onAppear(() => this.startShimmer())
              }
            }
            .height(19)
            .backgroundColor(this.isTunnelConnected() ? Color.Transparent :
              $r('app.color.nb_neutral_soft'))
            .linearGradient(this.isTunnelConnected() ? {
              angle: 135,
              colors: [['#4A9BFF', 0.0], ['#7B6BFF', 0.45], ['#2FD3B4', 1.0]]
            } : {
              angle: 135,
              colors: [['#00000000', 0.0], ['#00000000', 1.0]]
            })
            .borderRadius(9.5)
            .clip(true)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Column({ space: 1 }) {
            Text(this.statusTitle())
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.nb_text_primary'))
            if (this.statusSubtitle().length > 0) {
              Text(this.statusSubtitle())
                .fontSize(12)
                .fontColor($r('app.color.nb_text_secondary'))
            }
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%')
          .margin({ top: 10, bottom: 2 })

          if (this.statusNotice().length > 0) {
            Text(this.statusNotice())
              .fontSize(14)
              .fontColor(this.statusNotice().includes('失败') || this.statusNotice().includes('错误') ?
                $r('app.color.nb_error_text') : $r('app.color.nb_text_secondary'))
              .width('100%')
              .maxLines(3)
          }

          if (this.showConnectionPanel()) {
            Column({ space: 14 }) {
              Text('连接详情')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .width('100%')

              if (this.hasPendingConfiguration()) {
                Row({ space: 8 }) {
                  Text('!')
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.nb_on_accent'))
                    .textAlign(TextAlign.Center)
                    .width(18)
                    .height(18)
                    .borderRadius(9)
                    .backgroundColor($r('app.color.nb_relay_text'))
                  Text('服务端路由配置已更新，重新连接后生效')
                    .fontSize(12)
                    .fontColor($r('app.color.nb_relay_text'))
                    .layoutWeight(1)
                }
                .padding(10)
                .borderRadius(10)
                .backgroundColor($r('app.color.nb_relay_soft'))
                .width('100%')
                .alignItems(VerticalAlign.Center)
              }

              Column({ space: 10 }) {
                Row() {
                  Text('当前配置').fontSize(13).fontColor($r('app.color.nb_text_tertiary')).width('38%')
                  Text(this.configurationName)
                    .fontSize(13)
                    .fontColor($r('app.color.nb_text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }.width('100%')
                Divider().color($r('app.color.nb_inner_border')).strokeWidth(1)
                Row() {
                  Text('隧道状态').fontSize(13).fontColor($r('app.color.nb_text_tertiary')).width('38%')
                  Text(this.isTunnelConnected() ? '✓  隧道已建立' : '正在建立…').fontSize(13).fontColor($r('app.color.nb_text_primary'))
                }.width('100%')
                Divider().color($r('app.color.nb_inner_border')).strokeWidth(1)
                Row() {
                  Text('隧道地址').fontSize(13).fontColor($r('app.color.nb_text_tertiary')).width('38%')
                  Text(this.tunnelAddressLabel()).fontSize(13).fontColor($r('app.color.nb_text_primary')).layoutWeight(1)
                }.width('100%')
                Divider().color($r('app.color.nb_inner_border')).strokeWidth(1)
                Row() {
                  Text('DNS').fontSize(13).fontColor($r('app.color.nb_text_tertiary')).width('38%')
                  Text(this.dnsAddressLabel()).fontSize(13).fontColor($r('app.color.nb_text_primary')).layoutWeight(1)
                }.width('100%')
              }
              .padding(14)
              .borderRadius(14)
              .border({ width: 1, color: $r('app.color.nb_inner_border') })
              .backgroundColor($r('app.color.nb_card_background'))
              .width('100%')

              Column({ space: 10 }) {
                Row() {
                  Text(`Peers (${this.peerConnected})`)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                  Blank()
                  Text(this.peersExpanded ? '收起 ▴' : '展开 ▾')
                    .fontSize(13)
                    .fontColor($r('app.color.nb_accent'))
                }
                .width('100%')

                if (this.peersExpanded) {
                  Column({ space: 10 }) {
                    ForEach(this.peerDetails, (item: PeerDetailView) => {
                      Row({ space: 10 }) {
                        Text('')
                          .width(8)
                          .height(8)
                          .borderRadius(4)
                          .backgroundColor(item.connected ? $r('app.color.nb_status_connected') : $r('app.color.nb_status_idle'))
                        Column({ space: 2 }) {
                          Text(item.name)
                            .fontSize(14)
                            .fontWeight(FontWeight.Medium)
                            .fontColor($r('app.color.nb_text_primary'))
                          Text(item.ip.length > 0 ? item.ip : '未分配 IP')
                            .fontSize(12)
                            .fontColor($r('app.color.nb_text_tertiary'))
                        }
                        .layoutWeight(1)
                        Text(item.connectionType)
                          .fontSize(12)
                          .fontColor(item.connectionType === 'P2P' ? $r('app.color.nb_accent') :
                            (item.connectionType === 'Relay' ? $r('app.color.nb_relay_text') : $r('app.color.nb_text_hint')))
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .borderRadius(9)
                          .backgroundColor(item.connectionType === 'P2P' ? $r('app.color.nb_accent_soft') :
                            (item.connectionType === 'Relay' ? $r('app.color.nb_relay_soft') : $r('app.color.nb_neutral_soft')))
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                    }, (item: PeerDetailView) => `${item.name}|${item.ip}|${item.connectionType}|${item.handshaked}`)
                    if (this.peerDetails.length === 0) {
                      Text('暂无已连接节点')
                        .fontSize(12)
                        .fontColor($r('app.color.nb_text_hint'))
                        .width('100%')
                    }
                    Row() {
                      Text(`直连 ${this.peerP2PConnected} · 中继 ${this.peerRelayedConnected} · 握手 ${this.peerHandshake} · Tx/Rx ${this.peerBytesTx > 0 && this.peerBytesRx > 0 ? '活跃' : '等待中'}`)
                        .fontSize(12)
                        .fontColor($r('app.color.nb_text_tertiary'))
                    }
                    .width('100%')
                  }
                  .padding({ top: 8 })
                  .width('100%')
                }
              }
              .onClick(() => this.peersExpanded = !this.peersExpanded)
              .padding(14)
              .borderRadius(14)
              .border({ width: 1, color: $r('app.color.nb_inner_border') })
              .backgroundColor($r('app.color.nb_card_background'))
              .width('100%')

              Column({ space: 10 }) {
                Row() {
                  Text(`网络路由 (${this.appliedRoutes.length})`)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                  Blank()
                  Text(this.routesExpanded ? '收起 ▴' : '展开 ▾')
                    .fontSize(13)
                    .fontColor($r('app.color.nb_accent'))
                }
                .width('100%')

                if (this.routesExpanded) {
                  Column({ space: 10 }) {
                    ForEach(this.appliedRoutes, (item: RouteDetailView) => {
                      Row({ space: 10 }) {
                        Text('')
                          .width(8)
                          .height(8)
                          .borderRadius(4)
                          .backgroundColor($r('app.color.nb_status_connected'))
                        Column({ space: 2 }) {
                          Text(item.prefix)
                            .fontSize(13)
                            .fontColor($r('app.color.nb_text_primary'))
                          Text(item.via.length > 0 ? `经由 ${item.via}` : '本机隧道地址')
                            .fontSize(11)
                            .fontColor($r('app.color.nb_text_tertiary'))
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                    }, (item: RouteDetailView) => `${item.prefix}|${item.via}`)
                    if (this.appliedRoutes.length === 0) {
                      Text(this.clientRoutesDisabled ? '未接受服务端路由（设置已关闭）' : '暂无已下发路由')
                        .fontSize(12)
                        .fontColor($r('app.color.nb_text_hint'))
                        .width('100%')
                    }
                  }
                  .padding({ top: 8 })
                  .width('100%')
                }
              }
              .onClick(() => this.routesExpanded = !this.routesExpanded)
              .padding(14)
              .borderRadius(14)
              .border({ width: 1, color: $r('app.color.nb_inner_border') })
              .backgroundColor($r('app.color.nb_card_background'))
              .width('100%')

              // 域名资源走内部假地址转发，因此按真实域名和真实地址展示，而不是路由前缀。
              if (this.resolvedDomains.length > 0) {
                Column({ space: 10 }) {
                  Row() {
                    Text(`域名资源 (${this.resolvedDomains.length})`)
                      .fontSize(17)
                      .fontWeight(FontWeight.Bold)
                    Blank()
                    Text(this.domainsExpanded ? '收起 ▴' : '展开 ▾')
                      .fontSize(13)
                      .fontColor($r('app.color.nb_accent'))
                  }
                  .width('100%')

                  if (this.domainsExpanded) {
                    Column({ space: 10 }) {
                      Text('域名资源经隧道内 240.0.0.0/8 转发，客户端内部还原为下列真实地址')
                        .fontSize(11)
                        .fontColor($r('app.color.nb_text_tertiary'))
                        .width('100%')
                      ForEach(this.resolvedDomains, (item: ResolvedDomainView) => {
                        Row({ space: 10 }) {
                          Text('')
                            .width(8)
                            .height(8)
                            .borderRadius(4)
                            .backgroundColor($r('app.color.nb_status_connected'))
                          Column({ space: 2 }) {
                            Text(item.domain)
                              .fontSize(13)
                              .fontColor($r('app.color.nb_text_primary'))
                            Text(item.addresses.length > 0 ? item.addresses.join(' · ') : '尚未解析')
                              .fontSize(11)
                              .fontColor($r('app.color.nb_text_tertiary'))
                          }
                          .layoutWeight(1)
                          .alignItems(HorizontalAlign.Start)
                        }
                        .width('100%')
                        .alignItems(VerticalAlign.Center)
                      }, (item: ResolvedDomainView) => `${item.domain}|${item.addresses.join(',')}`)
                    }
                    .padding({ top: 8 })
                    .width('100%')
                  }
                }
                .onClick(() => this.domainsExpanded = !this.domainsExpanded)
                .padding(14)
                .borderRadius(14)
                .border({ width: 1, color: $r('app.color.nb_inner_border') })
                .backgroundColor($r('app.color.nb_card_background'))
                .width('100%')
              }
            }
            .padding(14)
            .borderRadius(20)
            .border({ width: 1, color: $r('app.color.nb_card_border') })
            .backgroundColor($r('app.color.nb_group_background'))
            .width('100%')
          } else {
            Column({ space: 16 }) {
              Text('Server Configurations')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .width('100%')

              if (this.isAddingConfiguration) {
                Column({ space: 12 }) {
                  TextInput({ placeholder: '配置名称（如：公司VPN）', text: this.configurationNameInput })
                    .height(52)
                    .fontSize(16)
                    .backgroundColor($r('app.color.nb_input_background'))
                    .borderRadius(26)
                    .padding({ left: 18, right: 18 })
                    .onChange((value: string) => this.configurationNameInput = value)
                  TextInput({ placeholder: '管理地址（如：https://…）', text: this.privateManagementUrl })
                    .height(52)
                    .fontSize(16)
                    .backgroundColor($r('app.color.nb_input_background'))
                    .borderRadius(26)
                    .padding({ left: 18, right: 18 })
                    .onChange((value: string) => this.privateManagementUrl = value)
                  TextInput({ placeholder: 'Setup Key（可选）', text: this.setupKeyInput })
                    .height(44)
                    .fontSize(15)
                    .type(InputType.Password)
                    .backgroundColor($r('app.color.nb_input_background'))
                    .borderRadius(22)
                    .padding({ left: 16, right: 16 })
                    .onChange((value: string) => this.setupKeyInput = value)
                  Row({ space: 12 }) {
                    Button('取消')
                      .height(44)
                      .fontSize(16)
                      .fontColor($r('app.color.nb_text_primary'))
                      .backgroundColor($r('app.color.nb_button_neutral'))
                      .borderRadius(22)
                      .onClick(() => this.cancelAddConfiguration())
                    Button('保存')
                      .height(44)
                      .fontSize(16)
                      .fontColor($r('app.color.nb_on_accent'))
                      .backgroundColor($r('app.color.nb_accent'))
                      .borderRadius(22)
                      .onClick(() => this.saveConfiguration())
                  }
                  .justifyContent(FlexAlign.Center)
                  .width('100%')
                }
                .padding(12)
                .borderRadius(18)
                .backgroundColor($r('app.color.nb_subtle_background'))
                .width('100%')
              } else {
                ForEach(this.profiles, (item: VpnProfile) => {
                  // 外层容器负责裁剪且自身不位移，内层整行左移才能把按钮带进可视区；
                  // 高度交给卡片内容决定，按钮沿交叉轴拉伸对齐。
                  Column() {
                    Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
                    Column({ space: 10 }) {
                      Row({ space: 12 }) {
                        Text(item.id === this.activeProfile ? '✓' : '')
                          .fontSize(13)
                          .fontWeight(FontWeight.Bold)
                          .fontColor($r('app.color.nb_on_accent'))
                          .textAlign(TextAlign.Center)
                          .width(26)
                          .height(26)
                          .borderRadius(13)
                          .backgroundColor(item.id === this.activeProfile ? $r('app.color.nb_accent') :
                            $r('app.color.nb_neutral_soft'))
                          .border(item.id === this.activeProfile ? { width: 0 } :
                            { width: 1, color: $r('app.color.nb_card_border') })
                        Column({ space: 2 }) {
                          Text(item.name)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor($r('app.color.nb_text_primary'))
                          Text(item.managementUrl.length > 0 ? item.managementUrl :
                            'Management 配置已安全保存')
                            .fontSize(12)
                            .fontColor($r('app.color.nb_text_secondary'))
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)

                      if (item.id === this.activeProfile) {
                        TextInput({ placeholder: 'Setup Key（可选）', text: this.setupKeyInput })
                          .height(40)
                          .fontSize(14)
                          .type(InputType.Password)
                          .backgroundColor($r('app.color.nb_input_background'))
                          .borderRadius(20)
                          .padding({ left: 14, right: 14 })
                          .width('100%')
                          .onChange((value: string) => this.setupKeyInput = value)
                      }
                    }
                    .padding(14)
                    .border({
                      width: this.profileCardBorderWidth(item.id),
                      color: item.id === this.activeProfile ? $r('app.color.nb_accent') :
                        $r('app.color.nb_card_border')
                    })
                    .borderRadius(this.profileCardRadius(item.id))
                    .backgroundColor($r('app.color.nb_card_background'))
                    .width('100%')
                    .flexShrink(0)
                    .onClick(() => {
                      if (this.swipedProfile.length > 0) {
                        this.closeProfileActions();
                        return;
                      }
                      this.selectProfile(item.id);
                    })

                    Text('编辑')
                      .fontSize(14)
                      .fontColor($r('app.color.nb_on_accent'))
                      .textAlign(TextAlign.Center)
                      .width(PROFILE_ACTION_WIDTH)
                      .flexShrink(0)
                      .backgroundColor($r('app.color.nb_status_idle'))
                      .onClick(() => this.beginEditConfiguration(item))
                    Text('重置')
                      .fontSize(14)
                      .fontColor($r('app.color.nb_on_accent'))
                      .textAlign(TextAlign.Center)
                      .width(PROFILE_ACTION_WIDTH)
                      .flexShrink(0)
                      .backgroundColor($r('app.color.nb_status_progress'))
                      .onClick(() => this.confirmResetProfile(item))
                    Text('删除')
                      .fontSize(14)
                      .fontColor($r('app.color.nb_on_accent'))
                      .textAlign(TextAlign.Center)
                      .width(PROFILE_ACTION_WIDTH)
                      .flexShrink(0)
                      .borderRadius({ topRight: 18, bottomRight: 18 })
                      .backgroundColor($r('app.color.nb_status_failed'))
                      .onClick(() => this.confirmDeleteProfile(item))
                  }
                  .width('100%')
                  .translate({ x: this.swipedProfile === item.id ? -PROFILE_ACTION_WIDTH * 3 : 0 })
                  .gesture(
                    PanGesture({ direction: PanDirection.Horizontal, distance: 12 })
                      .onActionEnd((event: GestureEvent) => {
                        if (event.offsetX < -24) {
                          this.openProfileActions(item.id);
                        } else if (event.offsetX > 24) {
                          this.closeProfileActions();
                        }
                      })
                  )
                  }
                  .width('100%')
                  .clip(true)
                }, (item: VpnProfile) => `${item.id}|${item.name}|${item.id === this.activeProfile}`)

                Button('+ 添加配置')
                  .height(44)
                  .fontSize(16)
                  .fontColor($r('app.color.nb_accent'))
                  .backgroundColor($r('app.color.nb_subtle_background'))
                  .borderRadius(22)
                  .onClick(() => this.beginAddConfiguration())
              }
            }
            .padding(16)
            .border({ width: 1, color: $r('app.color.nb_card_border') })
            .borderRadius(22)
            .backgroundColor($r('app.color.nb_card_background'))
            .width('100%')
          }
        }
        .padding({ left: 18, right: 18, top: 22, bottom: 132 })
        .constraintSize({ minHeight: '100%' })
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .height('100%')
      .width('100%')

      Column({ space: 8 }) {
        Button(this.primaryActionLabel())
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.nb_on_accent'))
          .backgroundColor(Color.Transparent)
          .linearGradient(this.isTunnelConnected() ? {
            angle: 135,
            colors: [['#FF6A3D', 0.0], ['#FF4B28', 0.55], ['#E63212', 1.0]]
          } : {
            angle: 135,
            colors: [['#3E9BFF', 0.0], ['#1E7BE8', 0.55], ['#1560C4', 1.0]]
          })
          .shadow({
            radius: 30,
            color: this.isTunnelConnected() ? '#73FF4B28' : '#661976D2',
            offsetX: 0,
            offsetY: 12
          })
          .opacity(this.explicitConnectionState === 'disconnecting' ? 0.65 : 1)
          .enabled(this.explicitConnectionState !== 'disconnecting')
          .borderRadius(24)
          .width('100%')
          .onClick(() => this.handlePrimaryAction())
      }
      // The bar itself is fully transparent so the page shows through; the button
      // floats above the content on its own gradient and glow.
      .padding({ left: 18, right: 18, top: 12, bottom: 20 })
      .backgroundColor(Color.Transparent)
      .width('100%')

      // 交互式登录覆盖层：授权页在应用内打开，IdP 重定向到 Core 监听的本机回调即完成。
      if (this.ssoActive) {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Text('登录以完成注册')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.nb_text_primary'))
            Blank()
            Text('取消')
              .fontSize(15)
              .fontColor($r('app.color.nb_accent'))
              .padding(6)
              .onClick(() => this.cancelSSOLogin())
          }
          .width('100%')

          Text(this.ssoMessage)
            .fontSize(12)
            .fontColor($r('app.color.nb_text_secondary'))
            .width('100%')

          if (this.ssoUserCode.length > 0) {
            Text(this.ssoUserCode)
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.nb_accent'))
              .textAlign(TextAlign.Center)
              .width('100%')
          }

          Text('若浏览器没有自动打开，可点击下方地址重试')
            .fontSize(11)
            .fontColor($r('app.color.nb_text_tertiary'))
            .width('100%')

          Text(this.ssoAuthUrl)
            .fontSize(11)
            .fontColor($r('app.color.nb_accent'))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .onClick(() => this.openSSOAuthPage())

          Blank()
        }
        .padding({ left: 16, right: 16, top: 16, bottom: 16 })
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.background_primary'))
      }
      // 全局设置覆盖层：所有服务器配置共用一套；改动立即保存，连接相关项重连后生效。
      if (this.settingsActive) {
        Column({ space: 0 }) {
          Row({ space: 10 }) {
            Text('设置')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.nb_text_primary'))
            Blank()
            Text('完成')
              .fontSize(15)
              .fontColor($r('app.color.nb_accent'))
              .padding(6)
              .onClick(() => this.settingsActive = false)
          }
          .width('100%')
          .padding({ bottom: 6 })

          if (this.settingsMessage.length > 0) {
            Text(this.settingsMessage)
              .fontSize(12)
              .fontColor($r('app.color.nb_text_secondary'))
              .width('100%')
              .padding({ bottom: 6 })
          }

          Scroll() {
            Column({ space: 14 }) {
              this.SettingsGroup('连接行为')
              this.SettingsToggle('打开应用即自动连接', '仅在该配置已登录时生效',
                this.settings.host.autoConnectOnLaunch, (on: boolean) => {
                  this.settings.host.autoConnectOnLaunch = on;
                  this.persistSettings();
                })
              this.SettingsToggle('自动应用服务端变更', '管理端新增资源后自动重建隧道，关闭后改为提示重连',
                this.settings.host.autoApplyServerChanges, (on: boolean) => {
                  this.settings.host.autoApplyServerChanges = on;
                  this.persistSettings();
                })
              this.SettingsToggle('登录优先使用设备码', '关闭后改用浏览器回调登录，少一步输码但依赖本机回调',
                this.settings.host.preferDeviceCodeLogin, (on: boolean) => {
                  this.settings.host.preferDeviceCodeLogin = on;
                  this.persistSettings();
                })

              this.SettingsGroup('网络')
              this.SettingsToggle('接管系统 DNS', '关闭后不修改系统 DNS，管理端下发的 DNS 将不生效',
                this.settings.core.manageDns, (on: boolean) => {
                  this.settings.core.manageDns = on;
                  this.persistSettings();
                })
              this.SettingsToggle('接受服务端路由', '关闭后只做点对点连接，不接收网段与域名资源',
                this.settings.core.acceptRoutes, (on: boolean) => {
                  this.settings.core.acceptRoutes = on;
                  this.persistSettings();
                })
              this.SettingsToggle('禁用 IPv6', '仅使用 IPv4 隧道',
                this.settings.core.disableIpv6, (on: boolean) => {
                  this.settings.core.disableIpv6 = on;
                  this.persistSettings();
                })
              this.SettingsInput('自定义上游 DNS', '留空表示使用管理端下发的上游',
                this.settings.core.customDnsAddress, (value: string) => {
                  this.settings.core.customDnsAddress = value.trim();
                  this.persistSettings();
                })
              this.SettingsInput('MTU', '留空为默认 1280，可填 1280-1500',
                this.settings.core.mtu > 0 ? `${this.settings.core.mtu}` : '', (value: string) => {
                  this.applyNumericSetting(value, (parsed: number) => this.settings.core.mtu = parsed);
                })
              this.SettingsInput('WireGuard 端口', '留空为默认，可填 1024-65535',
                this.settings.core.wireguardPort > 0 ? `${this.settings.core.wireguardPort}` : '',
                (value: string) => {
                  this.applyNumericSetting(value, (parsed: number) => this.settings.core.wireguardPort = parsed);
                })
              this.SettingsGroup('安全')
              this.SettingsToggle('阻止访问本机局域网', '开启后隧道不再放通对本地网段的访问',
                this.settings.core.blockLanAccess, (on: boolean) => {
                  this.settings.core.blockLanAccess = on;
                  this.persistSettings();
                })
              this.SettingsToggle('阻止入站连接', '只允许本机主动发起的连接',
                this.settings.core.blockInbound, (on: boolean) => {
                  this.settings.core.blockInbound = on;
                  this.persistSettings();
                })
              this.SettingsToggle('后量子加密握手', '启用 Rosenpass，需要对端同样支持',
                this.settings.core.rosenpassEnabled, (on: boolean) => {
                  this.settings.core.rosenpassEnabled = on;
                  this.persistSettings();
                })
              this.SettingsToggle('后量子加密宽松模式', '允许与不支持 Rosenpass 的对端继续连接',
                this.settings.core.rosenpassPermissive, (on: boolean) => {
                  this.settings.core.rosenpassPermissive = on;
                  this.persistSettings();
                })

              Text('网络与安全类设置在下次连接时生效。')
                .fontSize(11)
                .fontColor($r('app.color.nb_text_tertiary'))
                .width('100%')
                .padding({ top: 4, bottom: 24 })
            }
            .width('100%')
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .width('100%')
        }
        .padding({ left: 16, right: 16, top: 16 })
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.background_primary'))
      }
    }
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }

  @Builder
  SettingsGroup(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.nb_text_secondary'))
      .width('100%')
      .padding({ top: 6 })
  }

  @Builder
  SettingsToggle(title: string, hint: string, value: boolean, onChanged: (on: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.nb_text_primary'))
        Text(hint)
          .fontSize(11)
          .fontColor($r('app.color.nb_text_tertiary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .onChange((on: boolean) => onChanged(on))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SettingsInput(title: string, hint: string, value: string, onCommit: (text: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.nb_text_primary'))
        .width('100%')
      Text(hint)
        .fontSize(11)
        .fontColor($r('app.color.nb_text_tertiary'))
        .width('100%')
      TextInput({ text: value })
        .height(40)
        .fontSize(14)
        .backgroundColor($r('app.color.nb_input_background'))
        .borderRadius(20)
        .padding({ left: 14, right: 14 })
        .width('100%')
        .onSubmit(() => {
        })
        .onBlur(() => {
        })
        .onChange((text: string) => onCommit(text))
    }
    .width('100%')
  }
}

import { Want } from '@kit.AbilityKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import netbird from 'libnetbird.so';
import { deviceDisplayName } from '../vpn/DeviceIdentity';
import {
  HarmonyPlatformAdapter,
  HarmonyPlatformSummary,
  HarmonyVpnReconfigurationOptions
} from '../vpn/HarmonyPlatformAdapter';
import {
  runVpnExplicitConnectionCoordinatorSelfTest,
  VpnExplicitConnectionCallbacks,
  VpnExplicitConnectionCoordinator,
  VpnExplicitConnectionLifecycle
} from '../vpn/VpnExplicitConnectionCoordinator';
import {
  activeProfileId,
  credentialImportPath,
  profileConfigPath,
  profileLogPath,
  profileStatePath
} from '../vpn/ProfileStore';
import { coreSettingsJSON, readClientSettings } from '../vpn/ClientSettings';
import {
  CONTROL_CONFIGURE,
  CONTROL_CONNECT,
  CONTROL_DISCONNECT,
  CONTROL_INITIALIZE,
  CONTROL_SHUTDOWN,
  createVpnIpcPacket,
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
  parseVpnControlRequest,
  parseVpnIpcPacket,
  publishVpnPacket,
  runVpnIpcProtocolSelfTest,
  VPN_COMMAND_EVENT,
  VPN_STATUS_EVENT,
  VpnControlResponse,
  VpnIpcPacket
} from '../vpn/VpnIpc';

interface PrivateAuthenticationView {
  state: string;
  running: boolean;
  configured: boolean;
  persistent: boolean;
  lastError?: string;
}

interface PrivateCoreDataView {
  authentication: PrivateAuthenticationView;
}

interface PrivateCoreEnvelope {
  ok: boolean;
  code: number;
  message?: string;
  data?: PrivateCoreDataView;
}

interface NetworkBindingView {
  attempts: number;
  succeeded: number;
  failed: number;
}

interface IceDiagnosticsView {
  agentsCreated: number;
  offersReceived: number;
  gatherStarted: number;
  gatherFailed: number;
  localCandidates: number;
  remoteCandidates: number;
}

interface ControlPlatformView {
  preparationRunning?: boolean;
  preparationState?: string;
  lastError?: string;
}

interface ControlCoreDataView {
  networkBinding?: NetworkBindingView;
  iceDiagnostics?: IceDiagnosticsView;
  platform?: ControlPlatformView;
  managementConnected?: boolean;
  managementErrorCode?: string;
  signalConnected?: boolean;
  signalErrorCode?: string;
}

interface ControlCoreEnvelope {
  ok: boolean;
  code: number;
  message?: string;
  data?: ControlCoreDataView;
}

const DOMAIN = 0x4E42;
const TAG = 'NetBirdVpnExtension';
const DEBUG_ENABLE_REAL_VPN_FD = false;
const DEBUG_ENABLE_AUTOMATIC_VPN_RECONFIGURATION = false;
// A server-side change (new network resource, DNS group, route) advances the
// desired configuration while the tunnel keeps running the old one. Rebuilding the
// system VPN for the new revision is what makes such a change take effect without
// asking the user to reconnect.
const PRODUCTION_ENABLE_AUTOMATIC_VPN_RECONFIGURATION = true;
const RECONFIGURATION_WATCH_INTERVAL_MS = 2000;
// The engine keeps refining the desired configuration in bursts. Reconfiguring on
// the first pending revision would race those updates and invalidate the lease.
const RECONFIGURATION_SETTLE_MS = 1500;
// Each cycle rebuilds the system VPN, so keep a floor between two of them and a cap
// per connection in case the desired configuration never converges.
const RECONFIGURATION_MIN_INTERVAL_MS = 10000;
const RECONFIGURATION_MAX_ATTEMPTS = 3;
// Management rejects a peer whose identity it no longer knows with PermissionDenied
// (an SSO/setup-key requirement). Waiting for the preparation timeout would hide
// that answer behind two minutes of retries.
const IDENTITY_REJECTED_MARKER = 'VPN identity was rejected by Management';
const PRODUCTION_ENABLE_EXPLICIT_VPN_CONNECT = true;
const DEBUG_REAL_VPN_ROLLBACK_MS = 15000;
const NB_BUNDLE_NAME = 'org.huangedehw.nbconnect';

export default class NetbirdVpnExtensionAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private platformAdapter?: HarmonyPlatformAdapter;
  private commandSubscriber?: commonEventManager.CommonEventSubscriber;
  private debugRollbackTimer: number = -1;
  private platformPrepared: boolean = false;
  private privateConfigured: boolean = false;
  private explicitConnection: VpnExplicitConnectionCoordinator = new VpnExplicitConnectionCoordinator();
  private shutdownRequested: boolean = false;
  private commandQueue: Promise<void> = Promise.resolve();
  private controlResponseCache: Map<string, VpnControlResponse> = new Map();
  private controlResponseOrder: string[] = [];
  private reconfigurationWatchTimer: number = -1;
  private reconfigurationRunning: boolean = false;
  private reconfigurationSettleRevision: number = 0;
  private reconfigurationSettleSince: number = 0;
  private appliedConfigSignature: string = '';
  private reconfigurationAttempts: number = 0;
  private lastReconfigurationAt: number = 0;
  // 由全局设置控制，默认开启；关闭后服务端变更回到"提示重连"的行为。
  private autoReconfigurationEnabled: boolean = true;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'VPN_EXTENSION_CREATE action=%{public}s', want.action ?? 'none');
    this.startPlatformProcess().catch((error: Error) => {
      const message = error?.message ?? JSON.stringify(error);
      this.rollbackAfterPreparationFailure(message).catch(() => {
        hilog.error(DOMAIN, TAG, 'VPN_EXTENSION_PREPARE_ROLLBACK_FAIL');
      });
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'VPN_EXTENSION_DESTROY');
    this.shutdownRequested = true;
    this.platformPrepared = false;
    this.privateConfigured = false;
    this.explicitConnection.markStopped();
    const adapter = this.platformAdapter;
    this.platformAdapter = undefined;
    if (adapter === undefined) {
      this.finishPlatformStop();
      return;
    }
    adapter.rollback().then(() => this.finishPlatformStop()).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'VPN_PLATFORM_ROLLBACK_FAIL %{public}s', error.message);
      this.finishPlatformStop();
    });
  }

  private finishPlatformStop(): void {
    this.stopReconfigurationWatch();
    if (this.debugRollbackTimer >= 0) {
      clearTimeout(this.debugRollbackTimer);
      this.debugRollbackTimer = -1;
    }
    this.connection = undefined;
    this.platformPrepared = false;
    this.privateConfigured = false;
    this.explicitConnection.markStopped();
    this.controlResponseCache.clear();
    this.controlResponseOrder = [];
    const report = netbird.coreClearPlatformState();
    this.publishStatus(KIND_STOPPED, '', report);
    this.unsubscribeCommands();
  }

  private async startPlatformProcess(): Promise<void> {
    await this.subscribeCommands();
    const protocolReport = runVpnIpcProtocolSelfTest();
    hilog.info(DOMAIN, TAG, 'VPN_IPC_PROTOCOL_SELFTEST %{public}s', protocolReport);
    const explicitConnectionReport = await runVpnExplicitConnectionCoordinatorSelfTest();
    hilog.info(DOMAIN, TAG, 'VPN_EXPLICIT_CONNECTION_LIFECYCLE_SELFTEST %{public}s',
      explicitConnectionReport);
    if (PRODUCTION_ENABLE_EXPLICIT_VPN_CONNECT) {
      hilog.info(DOMAIN, TAG, 'VPN_EXPLICIT_CONNECT_POLICY_ENABLED user-command-only');
    } else {
      hilog.info(DOMAIN, TAG, 'VPN_EXPLICIT_CONNECT_DISABLED');
    }
    this.connection = vpnExtension.createVpnConnection(this.context);

    // Protect every socket created later by this VPN process. The temporary
    // private-LAN Management transport remains reachable through the physical
    // network while future tunnel recursion is prevented.
    await this.connection.protectProcessNet();
    if (this.shutdownRequested) {
      return;
    }
    this.ensureCore();
    // 全局客户端设置要在认证前交给 Core，认证成功时会随 config 一起持久化。
    this.applyClientSettings();
    const privateConfigured = await this.initializePrivateAuthentication();
    this.privateConfigured = privateConfigured;
    if (this.shutdownRequested) {
      return;
    }

    const applicationContext = this.context.getApplicationContext();
    const adapter = new HarmonyPlatformAdapter(this.connection);
    this.platformAdapter = adapter;
    const reconfigurationLifecycleReport = await adapter.runNoVpnReconfigurationLifecycleSelfTest();
    hilog.info(DOMAIN, TAG, 'VPN_RECONFIGURATION_LIFECYCLE_SELFTEST %{public}s',
      reconfigurationLifecycleReport);
    if (!DEBUG_ENABLE_AUTOMATIC_VPN_RECONFIGURATION) {
      hilog.info(DOMAIN, TAG, 'VPN_AUTOMATIC_RECONFIGURATION_DISABLED');
    }
    hilog.info(DOMAIN, TAG, 'VPN_AUTO_RECONFIGURATION_POLICY %{public}s',
      PRODUCTION_ENABLE_AUTOMATIC_VPN_RECONFIGURATION ? 'enabled-while-connected' : 'disabled');
    let summary: HarmonyPlatformSummary = await adapter.prepare();
    if (this.shutdownRequested) {
      await adapter.rollback();
      return;
    }
    this.platformPrepared = true;
    if (privateConfigured) {
      try {
        summary = await this.startCorePreparationWatched(adapter);
      } catch (error) {
        const err = error as Error;
        if (!err.message.includes(IDENTITY_REJECTED_MARKER)) {
          throw err;
        }
        // The stored identity is no longer accepted, so no amount of waiting or
        // retrying helps. Report it as a missing credential right away.
        await adapter.rollback();
        this.platformPrepared = false;
        hilog.warn(DOMAIN, TAG, 'VPN_PRIVATE_IDENTITY_REJECTED %{public}s', err.message);
        await this.publishStatusAwaited(KIND_NEEDS_CREDENTIAL, '',
          netbird.coreSetPlatformState(-1, true, false, false, false, err.message));
        return;
      }
      hilog.info(DOMAIN, TAG,
        'VPN_MANAGEMENT_NETWORK_MAP_READY auth=private configRevision=%{public}d preparationGeneration=%{public}d',
        summary.configRevision, summary.preparationGeneration);
    } else {
      hilog.info(DOMAIN, TAG, 'VPN_MANAGEMENT_SKIPPED_NO_PRIVATE_CONFIG');
    }
    this.explicitConnection.markReady();
    const selfTestReport = adapter.runNoVpnSelfTest();
    let report: string;
    if (DEBUG_ENABLE_REAL_VPN_FD && privateConfigured) {
      summary = await adapter.createDebugVpnAndProvideTunFD(NB_BUNDLE_NAME, 10000);
      hilog.info(DOMAIN, TAG,
        'VPN_REAL_FD_CONSUMED generation=%{public}d configRevision=%{public}d nonblocking=%{public}s',
        summary.preparationGeneration, summary.configRevision,
        summary.tunNonblockingVerified ? 'true' : 'false');
      await this.publishStatusAwaited(KIND_DEBUG_FD_PROBE, '', '{}');
      await new Promise<void>((resolve) => setTimeout(resolve, 2200));
      summary = adapter.refreshTunRuntimeStats();
      if (!summary.tunNonblockingVerified || summary.tunReadPackets < 1 || summary.tunInvalidPackets !== 0) {
        throw new Error('Harmony real fd raw packet or O_NONBLOCK verification failed');
      }
      hilog.info(DOMAIN, TAG,
        'VPN_REAL_FD_RAW_PACKET_OK read=%{public}d write=%{public}d invalid=%{public}d',
        summary.tunReadPackets, summary.tunWritePackets, summary.tunInvalidPackets);
      if (DEBUG_ENABLE_AUTOMATIC_VPN_RECONFIGURATION) {
        const pending = await adapter.requestDebugReconfiguration(5000);
        hilog.info(DOMAIN, TAG,
          'VPN_REAL_RECONFIGURATION_REQUESTED generation=%{public}d targetRevision=%{public}d',
          pending.reconfigurationGeneration, pending.reconfigurationTargetRevision);
        const options: HarmonyVpnReconfigurationOptions = {
          generation: pending.reconfigurationGeneration,
          targetRevision: pending.reconfigurationTargetRevision,
          stateFilePath: profileStatePath(applicationContext.filesDir, activeProfileId(applicationContext.filesDir)),
          cacheDir: applicationContext.cacheDir,
          logFilePath: profileLogPath(applicationContext.filesDir),
          timeoutMs: 10000,
          trustedApplication: NB_BUNDLE_NAME,
          phaseObserver: (phase: string) =>
            hilog.info(DOMAIN, TAG, 'VPN_REAL_RECONFIGURATION_PHASE %{public}s', phase)
        };
        summary = await adapter.reconfigureVpnForGeneration(options);
        hilog.info(DOMAIN, TAG,
          'VPN_REAL_RECONFIGURATION_CONSUMED generation=%{public}d preparationGeneration=%{public}d configRevision=%{public}d',
          summary.reconfigurationGeneration, summary.preparationGeneration, summary.configRevision);
        await this.publishStatusAwaited(KIND_DEBUG_FD_PROBE, '', '{}');
        await new Promise<void>((resolve) => setTimeout(resolve, 2200));
        summary = adapter.refreshTunRuntimeStats();
        if (!summary.tunNonblockingVerified || summary.tunReadPackets < 1 || summary.tunInvalidPackets !== 0) {
          throw new Error('Harmony recreated fd raw packet or O_NONBLOCK verification failed');
        }
        hilog.info(DOMAIN, TAG,
          'VPN_REAL_RECONFIGURATION_RAW_PACKET_OK read=%{public}d write=%{public}d invalid=%{public}d',
          summary.tunReadPackets, summary.tunWritePackets, summary.tunInvalidPackets);
      }
      report = netbird.coreStatus();
      this.debugRollbackTimer = setTimeout(() => {
        this.debugRollbackTimer = -1;
        adapter.rollback().then(() => {
          netbird.coreClearPlatformState();
          hilog.info(DOMAIN, TAG, 'VPN_DEBUG_AUTO_ROLLBACK_DONE');
        }).catch(() => hilog.error(DOMAIN, TAG, 'VPN_DEBUG_AUTO_ROLLBACK_FAIL'));
      }, DEBUG_REAL_VPN_ROLLBACK_MS);
    } else {
      report = netbird.coreSetPlatformState(-1, true, true, true, true, '');
    }
    hilog.info(DOMAIN, TAG,
      'VPN_PLATFORM_ADAPTER_PREPARED interfaces=%{public}d interfaceRevision=%{public}d desiredRevision=%{public}d',
      summary.interfaceCount, summary.interfaceRevision, summary.desiredRevision);
    hilog.info(DOMAIN, TAG, 'VPN_PLATFORM_ADAPTER_SELFTEST %{public}s', selfTestReport);
    if (DEBUG_ENABLE_REAL_VPN_FD && privateConfigured) {
      if (DEBUG_ENABLE_AUTOMATIC_VPN_RECONFIGURATION) {
        hilog.info(DOMAIN, TAG, 'VPN_REAL_RECONFIGURATION_ACTIVE_DEBUG');
      } else {
        hilog.info(DOMAIN, TAG, 'VPN_REAL_FD_ACTIVE_DEBUG');
      }
    } else {
      hilog.info(DOMAIN, TAG, 'VPN_PROCESS_PROTECTED_NO_TUN VPN_CREATE_DISABLED');
    }
    if (privateConfigured) {
      await this.publishStatusAwaited(KIND_READY, '', report);
      return;
    }
    // Preparation succeeded, but this profile has neither a persistent NetBird
    // identity from an earlier registration nor an SSO enrollment (not supported
    // yet), so an explicit connect would be rejected with -409. Reporting READY
    // here made the UI fire CONNECT and surface that raw error, so the missing
    // identity is reported as its own state instead.
    hilog.warn(DOMAIN, TAG, 'VPN_PRIVATE_IDENTITY_MISSING connect-not-available');
    await this.publishStatusAwaited(KIND_NEEDS_CREDENTIAL, '', report);
  }

  private applyClientSettings(): void {
    const settings = readClientSettings(this.context.getApplicationContext().filesDir);
    this.autoReconfigurationEnabled = settings.host.autoApplyServerChanges;
    try {
      const report = JSON.parse(netbird.coreSetClientSettings(coreSettingsJSON(settings))) as
        ControlCoreEnvelope;
      if (!report.ok) {
        hilog.warn(DOMAIN, TAG, 'VPN_CLIENT_SETTINGS_REJECTED %{public}s', report.message ?? '');
        return;
      }
      hilog.info(DOMAIN, TAG,
        'VPN_CLIENT_SETTINGS_APPLIED manageDns=%{public}s acceptRoutes=%{public}s autoApply=%{public}s',
        settings.core.manageDns ? 'true' : 'false', settings.core.acceptRoutes ? 'true' : 'false',
        settings.host.autoApplyServerChanges ? 'true' : 'false');
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, 'VPN_CLIENT_SETTINGS_FAIL %{public}s', err.message);
    }
  }

  private async initializePrivateAuthentication(): Promise<boolean> {
    const filesDir = this.context.getApplicationContext().filesDir;
    const profileId = activeProfileId(filesDir);
    const configPath = profileConfigPath(filesDir, profileId);
    const credentialPath = credentialImportPath(filesDir);
    hilog.info(DOMAIN, TAG, 'VPN_ACTIVE_PROFILE_SELECTED');
    const started = JSON.parse(netbird.coreStartPrivateAuthentication(
      deviceDisplayName(this.context), 'HarmonyOS', configPath, credentialPath)) as PrivateCoreEnvelope;
    if (!started.ok) {
      throw new Error(started.message ?? 'private NetBird authentication could not start');
    }

    const deadline = Date.now() + 50000;
    while (Date.now() < deadline) {
      const status = JSON.parse(netbird.coreStatus()) as PrivateCoreEnvelope;
      const authentication = status.data?.authentication;
      if (!status.ok || authentication === undefined) {
        throw new Error(status.message ?? 'private NetBird authentication status unavailable');
      }
      if (authentication.running) {
        await new Promise<void>((resolve) => setTimeout(resolve, 100));
        continue;
      }
      if (authentication.state === 'failed' || authentication.state === 'cancelled') {
        throw new Error(authentication.lastError ?? `private authentication ${authentication.state}`);
      }
      if (authentication.configured && authentication.persistent) {
        hilog.info(DOMAIN, TAG, 'VPN_PRIVATE_AUTH_READY state=%{public}s', authentication.state);
        return true;
      }
      return false;
    }
    throw new Error('private NetBird authentication timed out');
  }

  private async rollbackAfterPreparationFailure(message: string): Promise<void> {
    const adapter = this.platformAdapter;
    this.platformPrepared = false;
    this.explicitConnection.markFailed();
    if (adapter !== undefined) {
      await adapter.rollback();
    }
    if (this.shutdownRequested) {
      return;
    }
    this.ensureCore();
    // Carry the non-sensitive core, Management and Signal state with the failure so
    // the UI can show why preparation gave up instead of a bare timeout.
    const detailed = `${message}; core=${this.readPreparationDiagnostics()}`;
    const report = netbird.coreSetPlatformState(-1, true, false, false, false, detailed);
    this.publishStatus(KIND_ERROR, '', report);
    hilog.error(DOMAIN, TAG, 'VPN_EXTENSION_PREPARE_FAIL %{public}s', detailed);
  }

  private async subscribeCommands(): Promise<void> {
    this.commandSubscriber = await createVpnSubscriber(VPN_COMMAND_EVENT);
    commonEventManager.subscribe(this.commandSubscriber,
      (error: BusinessError, data?: commonEventManager.CommonEventData) => {
        if (error !== null && error.code !== 0) {
          hilog.error(DOMAIN, TAG, 'VPN_IPC_COMMAND_ERROR code=%{public}d', error.code);
          return;
        }
        if (data?.data === undefined) {
          return;
        }
        const packet = parseVpnIpcPacket(data.data);
        if (packet === undefined) {
          hilog.warn(DOMAIN, TAG, 'VPN_IPC_COMMAND_INVALID');
          return;
        }
        this.commandQueue = this.commandQueue.then(() => this.handleCommand(packet)).catch((commandError: Error) => {
          hilog.error(DOMAIN, TAG, 'VPN_IPC_COMMAND_HANDLE_FAIL %{public}s', commandError.message);
        });
      });
    hilog.info(DOMAIN, TAG, 'VPN_IPC_COMMAND_SUBSCRIBED');
  }

  private async handleCommand(packet: VpnIpcPacket): Promise<void> {
    hilog.info(DOMAIN, TAG, 'VPN_IPC_COMMAND_RECEIVED kind=%{public}s request=%{public}s',
      packet.kind, packet.requestId);
    if (packet.kind === KIND_STATUS_REQUEST) {
      const adapter = this.platformAdapter;
      if (adapter !== undefined) {
        const summary = adapter.refreshTunRuntimeStats();
        const routeCount = adapter.vpnConfig?.routes?.length ?? 0;
        hilog.info(DOMAIN, TAG,
          'VPN_PLATFORM_RUNTIME configRevision=%{public}d appliedRevision=%{public}d reconfigurationGeneration=%{public}d reconfigurationState=%{public}s targetRevision=%{public}d routeCount=%{public}d tunRead=%{public}d tunWrite=%{public}d tunInvalid=%{public}d',
          summary.configRevision, summary.appliedConfigRevision, summary.reconfigurationGeneration,
          summary.reconfigurationState, summary.reconfigurationTargetRevision, routeCount,
          summary.tunReadPackets, summary.tunWritePackets, summary.tunInvalidPackets);
      }
      await this.publishStatusAwaited(KIND_STATUS_RESPONSE, packet.requestId, netbird.coreStatus());
      return;
    }
    if (packet.kind !== KIND_CONTROL_REQUEST) {
      return;
    }
    await this.handleControlCommand(packet);
  }

  private async handleControlCommand(packet: VpnIpcPacket): Promise<void> {
    const request = parseVpnControlRequest(packet.payload);
    if (request === undefined) {
      hilog.warn(DOMAIN, TAG, 'VPN_IPC_CONTROL_INVALID request=%{public}s', packet.requestId);
      return;
    }

    const cached = this.controlResponseCache.get(packet.requestId);
    if (cached !== undefined) {
      const duplicate: VpnControlResponse = cached.command === request.command ? {
        command: cached.command,
        ok: cached.ok,
        code: cached.code,
        message: cached.message,
        duplicate: true,
        lifecycleState: cached.lifecycleState,
        status: cached.status
      } : {
        command: request.command,
        ok: false,
        code: -409,
        message: 'requestId already belongs to another command',
        duplicate: true,
        lifecycleState: this.explicitConnection.state,
        status: ''
      };
      await this.publishControlResponse(packet.requestId, duplicate);
      return;
    }

    const response = await this.executeControlCommand(request.command);
    this.cacheControlResponse(packet.requestId, response);
    await this.publishControlResponse(packet.requestId, response);
  }

  private explicitConnectionLifecycle(): VpnExplicitConnectionLifecycle {
    return new VpnExplicitConnectionCallbacks(
      async (): Promise<void> => this.connectExplicitVpn(),
      async (): Promise<void> => this.rollbackExplicitVpn(),
      async (): Promise<void> => this.rollbackExplicitVpn());
  }

  private async ensureExplicitPreparation(): Promise<void> {
    if (!this.privateConfigured) {
      throw new Error('VPN private configuration is not ready');
    }
    const adapter = this.platformAdapter;
    if (adapter === undefined || this.connection === undefined) {
      throw new Error('VPN platform adapter is unavailable');
    }
    if (this.platformPrepared) {
      return;
    }
    const applicationContext = this.context.getApplicationContext();
    await adapter.prepare();
    try {
      await adapter.startCorePreparation(
        profileStatePath(applicationContext.filesDir, activeProfileId(applicationContext.filesDir)),
        applicationContext.cacheDir,
        profileLogPath(applicationContext.filesDir),
        60000);
    } catch (error) {
      const err = error as Error;
      throw new Error(`${err.message}; core=${this.readPreparationDiagnostics()}`);
    }
    this.platformPrepared = true;
  }

  // Runs the core preparation while watching Management for an identity rejection,
  // so a peer whose server-side registration is gone fails fast with the real reason
  // instead of burning the full preparation timeout twice.
  private async startCorePreparationWatched(
    adapter: HarmonyPlatformAdapter): Promise<HarmonyPlatformSummary> {
    const applicationContext = this.context.getApplicationContext();
    let watchTimer = -1;
    const rejected = new Promise<HarmonyPlatformSummary>((_resolve, reject) => {
      watchTimer = setInterval(() => {
        const code = this.readIdentityRejection();
        if (code.length > 0) {
          reject(new Error(`${IDENTITY_REJECTED_MARKER} (management=${code})`));
        }
      }, 1000);
    });
    rejected.catch(() => {
      // Promise.race may settle with the preparation first; keep this observed.
    });
    try {
      return await Promise.race([
        adapter.startCorePreparation(
          profileStatePath(applicationContext.filesDir, activeProfileId(applicationContext.filesDir)),
          applicationContext.cacheDir,
          profileLogPath(applicationContext.filesDir),
          60000),
        rejected
      ]);
    } finally {
      if (watchTimer >= 0) {
        clearInterval(watchTimer);
        watchTimer = -1;
      }
    }
  }

  // PermissionDenied is what Management returns for "peer is not registered" and for
  // a login without setup key or SSO token; Unauthenticated is its equivalent on the
  // sync stream. Both mean this identity cannot be used again as it is.
  private readIdentityRejection(): string {
    try {
      const report = JSON.parse(netbird.coreStatus()) as ControlCoreEnvelope;
      const data = report.data;
      if (data === undefined || data.managementConnected === true) {
        return '';
      }
      const code = data.managementErrorCode ?? '';
      return code === 'PermissionDenied' || code === 'Unauthenticated' ? code : '';
    } catch (_) {
      return '';
    }
  }

  // Surfaces the non-sensitive Core preparation reason so a failed reconnect is
  // diagnosable instead of reporting only a generic timeout.
  private readPreparationDiagnostics(): string {
    try {
      const report = JSON.parse(netbird.coreStatus()) as ControlCoreEnvelope;
      const platform = report.data?.platform;
      const reason = platform?.lastError ?? '';
      const management = report.data?.managementConnected === true ? 'connected' :
        `down${(report.data?.managementErrorCode ?? '').length > 0 ? `/${report.data?.managementErrorCode}` : ''}`;
      const signal = report.data?.signalConnected === true ? 'connected' :
        `down${(report.data?.signalErrorCode ?? '').length > 0 ? `/${report.data?.signalErrorCode}` : ''}`;
      const diagnostics = `running=${platform?.preparationRunning ?? false},state=${platform?.preparationState ?? '-'}` +
        `,management=${management},signal=${signal}` +
        `${reason.length > 0 ? `,reason=${reason}` : ''}`;
      hilog.error(DOMAIN, TAG, 'VPN_PREPARATION_DIAGNOSTICS %{public}s', diagnostics);
      return diagnostics;
    } catch (_) {
      return 'unavailable';
    }
  }

  private logNativeNetworkDiagnostics(): void {
    try {
      const report = JSON.parse(netbird.coreStatus()) as ControlCoreEnvelope;
      const ice = report.data?.iceDiagnostics;
      if (ice !== undefined) {
        hilog.info(DOMAIN, TAG,
          'VPN_ICE_DIAGNOSTICS agents=%{public}d offers=%{public}d gathers=%{public}d gatherFailed=%{public}d localCandidates=%{public}d remoteCandidates=%{public}d',
          ice.agentsCreated, ice.offersReceived, ice.gatherStarted, ice.gatherFailed,
          ice.localCandidates, ice.remoteCandidates);
      }
    } catch (_) {
      hilog.error(DOMAIN, TAG, 'VPN_ICE_DIAGNOSTICS_UNAVAILABLE');
    }
  }

  private async connectExplicitVpn(): Promise<void> {
    await this.ensureExplicitPreparation();
    const adapter = this.platformAdapter;
    if (adapter === undefined) {
      throw new Error('VPN platform adapter disappeared before connect');
    }
    const summary = await adapter.createVpnAndProvideTunFD(10000);
    if (!summary.tunNonblockingVerified) {
      throw new Error('VPN explicit connection did not verify O_NONBLOCK');
    }
    hilog.info(DOMAIN, TAG,
      'VPN_EXPLICIT_CONNECT_CONSUMED preparationGeneration=%{public}d configRevision=%{public}d',
      summary.preparationGeneration, summary.configRevision);
    const report = JSON.parse(netbird.coreStatus()) as ControlCoreEnvelope;
    const binding = report.data?.networkBinding;
    if (binding !== undefined) {
      hilog.info(DOMAIN, TAG,
        'VPN_NATIVE_UDP_BIND attempts=%{public}d succeeded=%{public}d failed=%{public}d',
        binding.attempts, binding.succeeded, binding.failed);
    }
    setTimeout((): void => this.logNativeNetworkDiagnostics(), 10000);
    this.appliedConfigSignature = adapter.desiredConfigSignature();
    this.reconfigurationAttempts = 0;
    this.startReconfigurationWatch();
  }

  // A server-side change advances the desired configuration while the tunnel keeps
  // running the revision it was created with. The Core marks that gap as a pending
  // reconfiguration; rebuilding the system VPN for the new revision is what makes
  // the change effective without asking the user to reconnect.
  private startReconfigurationWatch(): void {
    if (!PRODUCTION_ENABLE_AUTOMATIC_VPN_RECONFIGURATION || !this.autoReconfigurationEnabled ||
      this.reconfigurationWatchTimer >= 0) {
      return;
    }
    this.reconfigurationSettleRevision = 0;
    this.reconfigurationSettleSince = 0;
    this.reconfigurationWatchTimer = setInterval((): void => this.pollReconfiguration(),
      RECONFIGURATION_WATCH_INTERVAL_MS);
    hilog.info(DOMAIN, TAG, 'VPN_AUTO_RECONFIGURATION_WATCH_STARTED');
  }

  private stopReconfigurationWatch(): void {
    if (this.reconfigurationWatchTimer < 0) {
      return;
    }
    clearInterval(this.reconfigurationWatchTimer);
    this.reconfigurationWatchTimer = -1;
    this.reconfigurationSettleRevision = 0;
    this.reconfigurationSettleSince = 0;
  }

  private pollReconfiguration(): void {
    const adapter = this.platformAdapter;
    if (this.reconfigurationRunning || this.shutdownRequested || adapter === undefined ||
      this.explicitConnection.state !== 'connected') {
      return;
    }
    let summary: HarmonyPlatformSummary;
    try {
      summary = adapter.getRuntimeSummary();
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, 'VPN_AUTO_RECONFIGURATION_SNAPSHOT_FAIL %{public}s', err.message);
      return;
    }
    if (summary.reconfigurationState !== 'pending' || summary.reconfigurationGeneration <= 0 ||
      summary.reconfigurationTargetRevision <= 0) {
      this.reconfigurationSettleRevision = 0;
      this.reconfigurationSettleSince = 0;
      return;
    }
    // The engine advances the revision right after a connect for changes that do not
    // touch the tunnel (it re-publishes the same addresses, routes and DNS). Rebuilding
    // the system VPN for those would drop the tunnel for nothing, so compare the
    // configuration itself and only act on a real difference.
    const signature = adapter.desiredConfigSignature();
    if (signature.length === 0 || signature === this.appliedConfigSignature) {
      this.reconfigurationSettleRevision = 0;
      this.reconfigurationSettleSince = 0;
      return;
    }
    if (this.reconfigurationAttempts >= RECONFIGURATION_MAX_ATTEMPTS) {
      return;
    }
    // Every cycle briefly rebuilds the tunnel, so keep a floor between two of them.
    if (this.lastReconfigurationAt > 0 &&
      Date.now() - this.lastReconfigurationAt < RECONFIGURATION_MIN_INTERVAL_MS) {
      return;
    }
    // Reconfiguring on a revision that is still moving would invalidate the lease
    // mid-cycle and tear the tunnel down, so wait for the burst to end first.
    if (summary.configRevision !== this.reconfigurationSettleRevision) {
      this.reconfigurationSettleRevision = summary.configRevision;
      this.reconfigurationSettleSince = Date.now();
      return;
    }
    if (Date.now() - this.reconfigurationSettleSince < RECONFIGURATION_SETTLE_MS) {
      return;
    }
    this.reconfigurationRunning = true;
    this.reconfigurationAttempts++;
    this.runAutomaticReconfiguration(adapter, summary).then((): void => {
      this.reconfigurationRunning = false;
      this.lastReconfigurationAt = Date.now();
      // A cycle that landed is progress, not a loop: only repeated failures and the
      // interval floor need to hold the next one back.
      this.reconfigurationAttempts = 0;
      this.appliedConfigSignature = adapter.desiredConfigSignature();
      this.reconfigurationSettleRevision = 0;
      this.reconfigurationSettleSince = 0;
    }).catch((error: Error): void => {
      this.reconfigurationRunning = false;
      this.stopReconfigurationWatch();
      this.handleReconfigurationFailure(error);
    });
  }

  private async runAutomaticReconfiguration(adapter: HarmonyPlatformAdapter,
    pending: HarmonyPlatformSummary): Promise<void> {
    const applicationContext = this.context.getApplicationContext();
    hilog.info(DOMAIN, TAG,
      'VPN_AUTO_RECONFIGURATION_START generation=%{public}d targetRevision=%{public}d appliedRevision=%{public}d',
      pending.reconfigurationGeneration, pending.reconfigurationTargetRevision,
      pending.appliedConfigRevision);
    hilog.info(DOMAIN, TAG, 'VPN_AUTO_RECONFIGURATION_DELTA applied=%{public}s desired=%{public}s',
      this.appliedConfigSignature, adapter.desiredConfigSignature());
    const options: HarmonyVpnReconfigurationOptions = {
      generation: pending.reconfigurationGeneration,
      targetRevision: pending.reconfigurationTargetRevision,
      stateFilePath: profileStatePath(applicationContext.filesDir,
        activeProfileId(applicationContext.filesDir)),
      cacheDir: applicationContext.cacheDir,
      logFilePath: profileLogPath(applicationContext.filesDir),
      timeoutMs: 15000,
      phaseObserver: (phase: string): void =>
        hilog.info(DOMAIN, TAG, 'VPN_AUTO_RECONFIGURATION_PHASE %{public}s', phase)
    };
    const applied = await adapter.reconfigureVpnForGeneration(options);
    hilog.info(DOMAIN, TAG,
      'VPN_AUTO_RECONFIGURATION_APPLIED generation=%{public}d configRevision=%{public}d appliedRevision=%{public}d routes=%{public}d',
      applied.reconfigurationGeneration, applied.configRevision, applied.appliedConfigRevision,
      adapter.vpnConfig?.routes?.length ?? 0);
    // Tell the host the change is already live so it stops asking for a reconnect,
    // and let it refresh the routes and DNS it shows without waiting for a poll.
    await this.publishStatusAwaited(KIND_RECONFIGURED, '', netbird.coreStatus());
  }

  // A failed reconfiguration has already rolled the platform back, so the tunnel is
  // gone. The engine cannot be prepared again in this process; report the error and
  // let the host rebuild the connection in a fresh one.
  private handleReconfigurationFailure(error: Error): void {
    this.platformPrepared = false;
    this.explicitConnection.markFailed();
    hilog.error(DOMAIN, TAG, 'VPN_AUTO_RECONFIGURATION_FAIL %{public}s', error.message);
    if (this.shutdownRequested) {
      return;
    }
    this.publishStatus(KIND_ERROR, '', netbird.coreSetPlatformState(-1, true, false, false, false,
      `VPN reconfiguration failed: ${error.message}`));
  }

  private async rollbackExplicitVpn(): Promise<void> {
    this.stopReconfigurationWatch();
    if (this.debugRollbackTimer >= 0) {
      clearTimeout(this.debugRollbackTimer);
      this.debugRollbackTimer = -1;
    }
    const adapter = this.platformAdapter;
    if (adapter !== undefined) {
      await adapter.rollback();
    }
    this.platformPrepared = false;
    hilog.info(DOMAIN, TAG, 'VPN_EXPLICIT_DISCONNECT_ROLLBACK_DONE');
  }

  private async executeControlCommand(command: string): Promise<VpnControlResponse> {
    if (command === CONTROL_INITIALIZE) {
      if (this.shutdownRequested) {
        return this.createControlError(command, -410, 'VPN process is shutting down');
      }
      this.ensureCore();
      return this.controlResponseFromCore(command, netbird.coreStatus());
    }
    if (command === CONTROL_CONFIGURE) {
      if (!this.platformPrepared || this.platformAdapter === undefined) {
        return this.createControlError(command, -409, 'VPN platform configuration is not ready');
      }
      return this.controlResponseFromCore(command, netbird.coreStatus());
    }
    if (command === CONTROL_CONNECT) {
      if (!PRODUCTION_ENABLE_EXPLICIT_VPN_CONNECT) {
        return this.createControlError(command, -403, 'Explicit VPN connect is disabled by policy');
      }
      if (this.platformAdapter === undefined) {
        return this.createControlError(command, -409, 'VPN platform adapter is not ready');
      }
      if (!this.privateConfigured) {
        return this.createControlError(command, -409, 'VPN private preparation is not ready');
      }
      try {
        const result = await this.explicitConnection.connect(this.explicitConnectionLifecycle());
        hilog.info(DOMAIN, TAG, 'VPN_EXPLICIT_CONNECT_CONFIRMED changed=%{public}s state=%{public}s',
          result.changed ? 'true' : 'false', result.state);
        return this.controlResponseFromCore(command, netbird.coreStatus());
      } catch (error) {
        const err = error as Error;
        return this.createControlError(command, -500, err.message);
      }
    }
    if (command === CONTROL_DISCONNECT) {
      try {
        const result = await this.explicitConnection.disconnect(this.explicitConnectionLifecycle());
        hilog.info(DOMAIN, TAG, 'VPN_EXPLICIT_DISCONNECT_CONFIRMED changed=%{public}s state=%{public}s',
          result.changed ? 'true' : 'false', result.state);
        return this.controlResponseFromCore(command, netbird.coreStatus());
      } catch (error) {
        const err = error as Error;
        return this.createControlError(command, -500, err.message);
      }
    }
    if (command === CONTROL_SHUTDOWN) {
      this.shutdownRequested = true;
      await this.rollbackExplicitVpn();
      this.platformAdapter = undefined;
      this.privateConfigured = false;
      this.explicitConnection.markStopped();
      return this.controlResponseFromCore(command, netbird.coreShutdown());
    }
    return this.createControlError(command, -400, 'unsupported VPN control command');
  }

  private controlResponseFromCore(command: string, status: string): VpnControlResponse {
    try {
      const envelope = JSON.parse(status) as ControlCoreEnvelope;
      return {
        command: command,
        ok: envelope.ok,
        code: envelope.code,
        message: envelope.message ?? '',
        duplicate: false,
        lifecycleState: this.explicitConnection.state,
        status: status
      };
    } catch (_) {
      return this.createControlError(command, -500, 'VPN Core returned an invalid response');
    }
  }

  private createControlError(command: string, code: number, message: string): VpnControlResponse {
    return {
      command: command,
      ok: false,
      code: code,
      message: message,
      duplicate: false,
      lifecycleState: this.explicitConnection.state,
      status: ''
    };
  }

  private cacheControlResponse(requestId: string, response: VpnControlResponse): void {
    this.controlResponseCache.set(requestId, response);
    this.controlResponseOrder.push(requestId);
    if (this.controlResponseOrder.length <= 64) {
      return;
    }
    const oldest = this.controlResponseOrder.shift();
    if (oldest !== undefined) {
      this.controlResponseCache.delete(oldest);
    }
  }

  private async publishControlResponse(requestId: string, response: VpnControlResponse): Promise<void> {
    await this.publishStatusAwaited(KIND_CONTROL_RESPONSE, requestId, JSON.stringify(response));
    hilog.info(DOMAIN, TAG,
      'VPN_IPC_CONTROL_RESPONSE command=%{public}s code=%{public}d duplicate=%{public}s request=%{public}s',
      response.command, response.code, response.duplicate ? 'true' : 'false', requestId);
  }

  private publishStatus(kind: string, requestId: string, payload: string): void {
    this.publishStatusAwaited(kind, requestId, payload).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'VPN_IPC_STATUS_PUBLISH_FAIL %{public}s', error.message);
    });
  }

  private async publishStatusAwaited(kind: string, requestId: string, payload: string): Promise<void> {
    const id = requestId.length > 0 ? requestId : `${kind}-${Date.now()}`;
    const packet = createVpnIpcPacket(kind, id, payload);
    await publishVpnPacket(VPN_STATUS_EVENT, packet, 0);
    hilog.info(DOMAIN, TAG, 'VPN_IPC_STATUS_SENT kind=%{public}s request=%{public}s', kind, id);
  }

  private unsubscribeCommands(): void {
    const subscriber = this.commandSubscriber;
    this.commandSubscriber = undefined;
    if (subscriber === undefined) {
      return;
    }
    commonEventManager.unsubscribe(subscriber, (error: BusinessError) => {
      if (error !== null && error.code !== 0) {
        hilog.warn(DOMAIN, TAG, 'VPN_IPC_UNSUBSCRIBE_FAIL code=%{public}d', error.code);
        return;
      }
      hilog.info(DOMAIN, TAG, 'VPN_IPC_COMMAND_UNSUBSCRIBED');
    });
  }

  private ensureCore(): void {
    try {
      const status = JSON.parse(netbird.coreStatus()) as Record<string, Object>;
      if (status['ok'] === true) {
        return;
      }
    } catch (_) {
    }
    netbird.coreInit(deviceDisplayName(this.context), 'HarmonyOS', '{}');
    hilog.info(DOMAIN, TAG, 'VPN_CORE_INIT_OK');
  }
}

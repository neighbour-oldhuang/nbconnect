import { BusinessError } from '@kit.BasicServicesKit';
import { connection, vpnExtension } from '@kit.NetworkKit';
import netbird from 'libnetbird.so';
import {
  runVpnReconfigurationCoordinatorSelfTest,
  VpnReconfigurationCoordinator,
  VpnReconfigurationLease,
  VpnReconfigurationLifecycle,
  VpnReconfigurationRequest
} from './VpnReconfigurationCoordinator';

export enum HarmonyPlatformState {
  IDLE = 'idle',
  PREPARING = 'preparing',
  PREPARED = 'prepared',
  CONFIGURED = 'configured',
  ROLLING_BACK = 'rolling-back',
  STOPPED = 'stopped',
  ERROR = 'error'
}

interface PhysicalInterface {
  name: string;
  index: number;
  mtu: number;
  up: boolean;
  broadcast: boolean;
  loopback: boolean;
  pointToPoint: boolean;
  multicast: boolean;
  addresses: Array<string>;
}

interface PhysicalInterfaceSet {
  interfaces: Array<PhysicalInterface>;
}

// The Core allocates fake addresses for domain resources out of these reserved
// blocks (240.0.0.0/8 per RFC 1112 and 0100::/64 per RFC 6666). Routing the blocks
// as a whole keeps per-domain lookups from touching the system VPN configuration.
const FAKE_IP_V4_BLOCK = '240.0.0.0/8';
const FAKE_IP_V6_BLOCK = '0100::/64';

export interface HarmonyDesiredSnapshot {
  revision: number;
  interfaceRevision: number;
  preparationGeneration: number;
  preparationState: string;
  configRevision: number;
  appliedConfigRevision: number;
  reconfigurationGeneration: number;
  reconfigurationState: string;
  reconfigurationTargetRevision: number;
  interfacesReady: boolean;
  configReady: boolean;
  addresses: Array<string>;
  routes: Array<string>;
  dnsAddresses: Array<string>;
  searchDomains: Array<string>;
  mtu: number;
}

interface NativeEnvelope {
  ok: boolean;
  code: number;
  message?: string;
  data?: HarmonyDesiredSnapshot;
}

interface TunRuntimeStats {
  nonblockingVerified: boolean;
  readPackets: number;
  writePackets: number;
  invalidPackets: number;
}

interface TunRuntimeEnvelope {
  ok: boolean;
  code: number;
  message?: string;
  data?: TunRuntimeStats;
}

export interface HarmonyPlatformSummary {
  state: HarmonyPlatformState;
  interfaceCount: number;
  interfaceRevision: number;
  desiredRevision: number;
  preparationGeneration: number;
  preparationState: string;
  configRevision: number;
  appliedConfigRevision: number;
  reconfigurationGeneration: number;
  reconfigurationState: string;
  reconfigurationTargetRevision: number;
  configReady: boolean;
  vpnCreateAttempted: boolean;
  vpnCreated: boolean;
  tunNonblockingVerified: boolean;
  tunReadPackets: number;
  tunWritePackets: number;
  tunInvalidPackets: number;
}

export interface HarmonyVpnReconfigurationOptions {
  generation: number;
  targetRevision: number;
  stateFilePath: string;
  cacheDir: string;
  logFilePath: string;
  timeoutMs: number;
  trustedApplication?: string;
  phaseObserver?: (phase: string) => void;
}

class HarmonyVpnReconfigurationRequest implements VpnReconfigurationRequest {
  generation: number;
  targetRevision: number;

  constructor(generation: number, targetRevision: number) {
    this.generation = generation;
    this.targetRevision = targetRevision;
  }
}

export class HarmonyPlatformAdapter {
  private readonly connection: vpnExtension.VpnConnection;
  private readonly reconfigurationCoordinator: VpnReconfigurationCoordinator =
    new VpnReconfigurationCoordinator();
  private observer?: connection.NetConnection;
  private pollTimer: number = -1;
  private refreshTimer: number = -1;
  private refreshRunning: boolean = false;
  private rollbackTask?: Promise<void>;
  private platformState: HarmonyPlatformState = HarmonyPlatformState.IDLE;
  private interfaceCount: number = 0;
  private interfaceRevision: number = 0;
  private desiredRevision: number = 0;
  private preparationGeneration: number = 0;
  private preparationState: string = 'idle';
  private configRevision: number = 0;
  private appliedConfigRevision: number = 0;
  private reconfigurationGeneration: number = 0;
  private reconfigurationState: string = 'idle';
  private reconfigurationTargetRevision: number = 0;
  private desiredConfig?: vpnExtension.VpnConfig;

  // A rejected create() can still transiently install a system VPN. Track the
  // attempt before awaiting the Promise so rollback always calls destroy().
  private vpnCreateAttempted: boolean = false;
  private vpnCreated: boolean = false;
  private tunRuntimeStats: TunRuntimeStats = {
    nonblockingVerified: false,
    readPackets: 0,
    writePackets: 0,
    invalidPackets: 0
  };

  constructor(vpnConnection: vpnExtension.VpnConnection) {
    this.connection = vpnConnection;
  }

  get state(): HarmonyPlatformState {
    return this.platformState;
  }

  get vpnConfig(): vpnExtension.VpnConfig | undefined {
    return this.desiredConfig;
  }

  // The revision counter also advances for changes that do not alter the tunnel, so
  // a caller deciding whether the system VPN must be rebuilt compares this signature
  // of the addresses, routes, DNS servers and MTU instead of the revision.
  //
  // Search domains are deliberately excluded: the engine publishes the match domains
  // of domain resources only after its resolver starts, which happens after the
  // tunnel exists. A freshly built tunnel therefore always trails by one search
  // domain update, and rebuilding for that difference would never converge. Name
  // resolution does not depend on it either, since the system resolver already points
  // at the NetBird resolver that owns those domains.
  desiredConfigSignature(): string {
    const config = this.desiredConfig;
    if (config === undefined) {
      return '';
    }
    const addresses = config.addresses
      .map((item: connection.LinkAddress) => `${item.address.address}/${item.prefixLength}`)
      .sort()
      .join(',');
    const routes = (config.routes ?? [])
      .map((item: connection.RouteInfo) =>
        `${item.destination.address.address}/${item.destination.prefixLength}`)
      .filter((prefix: string) => !this.isCoveredByFakeIPBlock(prefix))
      .sort()
      .join(',');
    const dns = (config.dnsAddresses ?? []).slice().sort().join(',');
    return `a=${addresses};r=${routes};d=${dns};m=${config.mtu ?? 0}`;
  }

  // A fake IP route only refines a block the tunnel already carries, so it must not
  // count as a configuration change: rebuilding the tunnel for every resolved domain
  // would drop the connection repeatedly for no gain.
  private isCoveredByFakeIPBlock(prefix: string): boolean {
    if (prefix === FAKE_IP_V4_BLOCK || prefix === FAKE_IP_V6_BLOCK) {
      return false;
    }
    return prefix.startsWith('240.') || prefix.toLowerCase().startsWith('100:');
  }

  getRuntimeSummary(): HarmonyPlatformSummary {
    this.pullDesiredSnapshot();
    return this.summary();
  }

  async prepare(): Promise<HarmonyPlatformSummary> {
    if (this.platformState === HarmonyPlatformState.PREPARED ||
      this.platformState === HarmonyPlatformState.CONFIGURED) {
      return this.summary();
    }
    if (this.platformState === HarmonyPlatformState.PREPARING) {
      throw new Error('Harmony platform adapter preparation is already in progress');
    }

    this.rollbackTask = undefined;
    this.platformState = HarmonyPlatformState.PREPARING;
    try {
      await this.registerNetworkObserver();
      await this.refreshPhysicalInterfaces();
      this.startSnapshotPolling();
      this.platformState = HarmonyPlatformState.PREPARED;
      this.pullDesiredSnapshot();
      return this.summary();
    } catch (_) {
      this.platformState = HarmonyPlatformState.ERROR;
      await this.rollback();
      throw new Error('Harmony platform adapter preparation failed');
    }
  }

  async startCorePreparation(stateFilePath: string, cacheDir: string,
    logFilePath: string, timeoutMs: number = 30000): Promise<HarmonyPlatformSummary> {
    if (this.platformState !== HarmonyPlatformState.PREPARED &&
      this.platformState !== HarmonyPlatformState.CONFIGURED) {
      throw new Error('Harmony platform adapter must be prepared before core preparation');
    }
    if (timeoutMs <= 0) {
      throw new Error('Harmony core preparation timeout must be positive');
    }
    const started = this.parseEnvelope(netbird.coreStartPreparation(stateFilePath, cacheDir, logFilePath));
    if (!started.ok) {
      throw new Error(started.message ?? 'Harmony core preparation could not start');
    }

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const snapshot = this.readSnapshot();
      this.applyDesiredSnapshot(snapshot);
      if (snapshot.preparationState === 'awaiting-fd' && snapshot.configReady &&
        this.desiredConfig !== undefined) {
        return this.summary();
      }
      if (snapshot.preparationState === 'cancelled' || snapshot.preparationState === 'rolled-back') {
        throw new Error(`Harmony core preparation stopped: ${snapshot.preparationState}`);
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 100));
    }

    await this.rollback();
    throw new Error('Harmony core preparation timed out and was rolled back');
  }

  async beginCoreReconfiguration(generation: number, targetRevision: number,
    timeoutMs: number = 30000): Promise<HarmonyPlatformSummary> {
    if (timeoutMs <= 0) {
      throw new Error('Harmony core reconfiguration timeout must be positive');
    }
    const current = this.readSnapshot();
    // A configuration update during the cycle pushes the Core's target forward. Only
    // a target that fell behind the request, or a different generation, is stale.
    if (current.reconfigurationState !== 'pending' ||
      current.reconfigurationGeneration !== generation ||
      current.reconfigurationTargetRevision < targetRevision) {
      throw new Error('Harmony core reconfiguration generation or target is stale');
    }
    const started = this.parseEnvelope(
      netbird.coreBeginReconfiguration(generation, current.reconfigurationTargetRevision));
    if (!started.ok) {
      throw new Error(started.message ?? 'Harmony core reconfiguration could not begin');
    }

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const snapshot = this.readSnapshot();
      this.applyDesiredSnapshot(snapshot);
      if (snapshot.reconfigurationGeneration !== generation) {
        throw new Error('Harmony core reconfiguration generation changed while stopping');
      }
      if (snapshot.reconfigurationState === 'old-fd-released') {
        return this.summary();
      }
      if (snapshot.reconfigurationState === 'failed' ||
        snapshot.reconfigurationState === 'rolled-back') {
        throw new Error(`Harmony core reconfiguration stopped: ${snapshot.reconfigurationState}`);
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 50));
    }

    await this.rollback();
    throw new Error('Harmony old fd release timed out and was rolled back');
  }

  async restartCorePreparation(generation: number, stateFilePath: string, cacheDir: string,
    logFilePath: string, timeoutMs: number = 30000): Promise<HarmonyPlatformSummary> {
    if (timeoutMs <= 0) {
      throw new Error('Harmony core restart timeout must be positive');
    }
    const started = this.parseEnvelope(
      netbird.coreRestartPreparation(generation, stateFilePath, cacheDir, logFilePath));
    if (!started.ok) {
      throw new Error(started.message ?? 'Harmony core preparation could not restart');
    }

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const snapshot = this.readSnapshot();
      this.applyDesiredSnapshot(snapshot);
      if (snapshot.reconfigurationGeneration !== generation) {
        throw new Error('Harmony core restart generation changed');
      }
      if (snapshot.reconfigurationState === 'awaiting-new-fd' &&
        snapshot.preparationState === 'awaiting-fd' && snapshot.configReady &&
        this.desiredConfig !== undefined) {
        return this.summary();
      }
      if (snapshot.reconfigurationState === 'failed' ||
        snapshot.reconfigurationState === 'rolled-back') {
        throw new Error(`Harmony core restart stopped: ${snapshot.reconfigurationState}`);
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 100));
    }

    await this.rollback();
    throw new Error('Harmony core restart timed out and was rolled back');
  }

  provideCoreTunFDForGeneration(tunFd: number, preparationGeneration: number,
    reconfigurationGeneration: number, configRevision: number): HarmonyPlatformSummary {
    if (!Number.isInteger(tunFd) || tunFd <= 0) {
      throw new Error('Harmony tunnel fd must be a positive integer');
    }
    const provided = this.parseEnvelope(netbird.coreProvideTunFDForGeneration(
      tunFd, preparationGeneration, reconfigurationGeneration, configRevision));
    if (!provided.ok) {
      throw new Error(provided.message ?? 'Harmony core rejected the versioned tunnel fd');
    }
    this.applyDesiredSnapshot(this.readSnapshot());
    return this.summary();
  }

  async requestDebugReconfiguration(timeoutMs: number = 5000): Promise<HarmonyPlatformSummary> {
    if (timeoutMs <= 0) {
      throw new Error('Harmony debug reconfiguration timeout must be positive');
    }
    const triggered = this.parseEnvelope(netbird.coreDebugRequestReconfiguration());
    if (!triggered.ok) {
      throw new Error(triggered.message ?? 'Harmony debug reconfiguration could not be requested');
    }
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const snapshot = this.readSnapshot();
      this.applyDesiredSnapshot(snapshot);
      if (snapshot.reconfigurationState === 'pending' &&
        snapshot.reconfigurationGeneration > 0 &&
        snapshot.reconfigurationTargetRevision === snapshot.configRevision) {
        return this.summary();
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 50));
    }
    throw new Error('Harmony debug reconfiguration pending state timed out');
  }

  async reconfigureVpnForGeneration(options: HarmonyVpnReconfigurationOptions):
    Promise<HarmonyPlatformSummary> {
    if (options.stateFilePath.length === 0 || options.cacheDir.length === 0 ||
      options.logFilePath.length === 0 || options.timeoutMs <= 0) {
      throw new Error('Harmony VPN reconfiguration options are invalid');
    }
    if (!this.vpnCreated || !this.vpnCreateAttempted) {
      throw new Error('Harmony VPN reconfiguration requires an active platform VPN');
    }
    const request: VpnReconfigurationRequest = new HarmonyVpnReconfigurationRequest(
      options.generation, options.targetRevision);
    const lifecycle: VpnReconfigurationLifecycle =
      new HarmonyAdapterReconfigurationLifecycle(this, options);
    await this.reconfigurationCoordinator.run(request, lifecycle);
    return this.summary();
  }

  async runNoVpnReconfigurationLifecycleSelfTest(): Promise<string> {
    return runVpnReconfigurationCoordinatorSelfTest();
  }

  async createVpnAndProvideTunFD(timeoutMs: number = 10000): Promise<HarmonyPlatformSummary> {
    if (timeoutMs <= 0) {
      throw new Error('Harmony VPN connect timeout must be positive');
    }
    // Right after the network map arrives the engine keeps refining the desired
    // configuration (routes first, DNS and resource updates a moment later).
    // Claiming the lease on a moving revision made the consumption abort with
    // "lease changed before consumption", so wait for the revision to hold still.
    const snapshot = await this.awaitSettledDesiredSnapshot(timeoutMs);
    this.applyDesiredSnapshot(snapshot);
    if (this.platformState !== HarmonyPlatformState.CONFIGURED || this.desiredConfig === undefined ||
      snapshot.preparationState !== 'awaiting-fd' || !snapshot.configReady ||
      snapshot.preparationGeneration <= 0 || snapshot.configRevision <= 0 ||
      snapshot.reconfigurationGeneration !== 0) {
      throw new Error('Harmony explicit VPN connect prerequisites are not satisfied');
    }

    this.resetTunRuntimeStats();
    try {
      const tunFd = await this.createVpnWithTimeout(this.desiredConfig, timeoutMs);
      this.provideCoreTunFDForGeneration(tunFd, snapshot.preparationGeneration,
        snapshot.reconfigurationGeneration, snapshot.configRevision);

      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const current = this.readSnapshot();
        this.applyDesiredSnapshot(current);
        if (current.preparationGeneration !== snapshot.preparationGeneration ||
          current.configRevision !== snapshot.configRevision || current.reconfigurationGeneration !== 0) {
          throw new Error('Harmony explicit VPN connect lease changed before consumption');
        }
        if (current.preparationState === 'fd-consumed' &&
          current.appliedConfigRevision === snapshot.configRevision) {
          const platform = this.parseEnvelope(
            netbird.coreSetPlatformState(tunFd, true, true, true, true, ''));
          if (!platform.ok) {
            throw new Error(platform.message ?? 'Harmony explicit VPN platform state update failed');
          }
          this.refreshTunRuntimeStats();
          return this.summary();
        }
        if (current.preparationState === 'cancelled' || current.preparationState === 'rolled-back') {
          throw new Error(`Harmony explicit VPN consumption stopped: ${current.preparationState}`);
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 50));
      }
      throw new Error('Harmony explicit VPN consumption timed out');
    } catch (error) {
      await this.rollback();
      const err = error as Error;
      throw new Error(`Harmony explicit VPN connect failed: ${err.message}`);
    }
  }

  // Returns the desired snapshot once its revision stopped moving, or the last
  // one seen when the engine keeps updating past the settle deadline.
  private async awaitSettledDesiredSnapshot(timeoutMs: number): Promise<HarmonyDesiredSnapshot> {
    const settleWindowMs = 500;
    const deadline = Date.now() + Math.min(timeoutMs, 5000);
    let previous = this.readSnapshot();
    let stableSince = Date.now();
    while (Date.now() < deadline) {
      await new Promise<void>((resolve) => setTimeout(resolve, 100));
      const current = this.readSnapshot();
      const moved = current.configRevision !== previous.configRevision ||
        current.preparationGeneration !== previous.preparationGeneration ||
        current.reconfigurationGeneration !== previous.reconfigurationGeneration;
      previous = current;
      if (moved) {
        stableSince = Date.now();
        continue;
      }
      if (Date.now() - stableSince >= settleWindowMs) {
        return current;
      }
    }
    return previous;
  }

  async createDebugVpnAndProvideTunFD(bundleName: string,
    timeoutMs: number = 10000): Promise<HarmonyPlatformSummary> {
    if (bundleName.length === 0 || timeoutMs <= 0) {
      throw new Error('Harmony debug VPN gate arguments are invalid');
    }
    const snapshot = this.readSnapshot();
    this.applyDesiredSnapshot(snapshot);
    if (this.platformState !== HarmonyPlatformState.CONFIGURED || this.desiredConfig === undefined ||
      snapshot.preparationState !== 'awaiting-fd' || !snapshot.configReady ||
      snapshot.preparationGeneration <= 0 || snapshot.configRevision <= 0 ||
      snapshot.reconfigurationGeneration !== 0) {
      throw new Error('Harmony debug VPN create prerequisites are not satisfied');
    }

    this.resetTunRuntimeStats();

    const debugConfig = this.buildDebugVpnConfig(this.desiredConfig, bundleName);
    try {
      const tunFd = await this.createVpnWithTimeout(debugConfig, timeoutMs);
      this.provideCoreTunFDForGeneration(tunFd, snapshot.preparationGeneration,
        snapshot.reconfigurationGeneration, snapshot.configRevision);

      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const current = this.readSnapshot();
        this.applyDesiredSnapshot(current);
        if (current.preparationGeneration !== snapshot.preparationGeneration ||
          current.configRevision !== snapshot.configRevision) {
          throw new Error('Harmony real fd generation changed before consumption');
        }
        if (current.preparationState === 'fd-consumed' &&
          current.appliedConfigRevision === snapshot.configRevision) {
          const platform = this.parseEnvelope(
            netbird.coreSetPlatformState(tunFd, true, true, true, true, ''));
          if (!platform.ok) {
            throw new Error(platform.message ?? 'Harmony real fd platform state update failed');
          }
          this.refreshTunRuntimeStats();
          return this.summary();
        }
        if (current.preparationState === 'cancelled' || current.preparationState === 'rolled-back') {
          throw new Error(`Harmony real fd consumption stopped: ${current.preparationState}`);
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 50));
      }
      throw new Error('Harmony real fd consumption timed out');
    } catch (error) {
      await this.rollback();
      const err = error as Error;
      throw new Error(`Harmony debug VPN create failed: ${err.message}`);
    }
  }

  private async createVpnWithTimeout(config: vpnExtension.VpnConfig, timeoutMs: number): Promise<number> {
    if (timeoutMs <= 0) {
      throw new Error('Harmony VPN create timeout must be positive');
    }
    this.vpnCreateAttempted = true;
    let timedOut = false;
    let timer = -1;
    const createTask = this.connection.create(config).then(async (tunFd: number) => {
      if (timedOut) {
        try {
          await this.connection.destroy();
        } catch (_) {
        }
        throw new Error('Harmony VpnConnection resolved after create timeout');
      }
      return tunFd;
    });
    createTask.catch(() => {
      // Promise.race may already be settled by timeout; keep the late result observed.
    });
    const timeoutTask = new Promise<number>((_resolve, reject) => {
      timer = setTimeout(() => {
        timedOut = true;
        reject(new Error('Harmony VpnConnection create timed out'));
      }, timeoutMs);
    });
    try {
      const tunFd = await Promise.race([createTask, timeoutTask]);
      if (timer >= 0) {
        clearTimeout(timer);
      }
      if (!Number.isInteger(tunFd) || tunFd <= 0) {
        throw new Error('Harmony VpnConnection returned an invalid fd');
      }
      this.vpnCreated = true;
      return tunFd;
    } catch (error) {
      if (timer >= 0) {
        clearTimeout(timer);
      }
      try {
        await this.connection.destroy();
      } catch (_) {
      }
      this.vpnCreated = false;
      // Keep vpnCreateAttempted=true even when the immediate destroy succeeds.
      // A timed-out native create may settle later and transiently reinstall VPN;
      // the outer rollback must therefore execute destroy() again.
      const err = error as Error;
      throw new Error(err.message);
    }
  }

  async destroyCurrentVpnForReconfiguration(): Promise<void> {
    if (!this.vpnCreateAttempted && !this.vpnCreated) {
      throw new Error('Harmony old VPN is not active');
    }
    await this.connection.destroy();
    this.vpnCreated = false;
    this.vpnCreateAttempted = false;
  }

  async createVpnForReconfiguration(lease: VpnReconfigurationLease,
    options: HarmonyVpnReconfigurationOptions): Promise<number> {
    const snapshot = this.readSnapshot();
    this.applyDesiredSnapshot(snapshot);
    if (this.desiredConfig === undefined || snapshot.preparationGeneration !== lease.preparationGeneration ||
      snapshot.reconfigurationGeneration !== lease.generation ||
      snapshot.configRevision !== lease.configRevision) {
      throw new Error('Harmony VPN config changed before recreate');
    }
    const config = options.trustedApplication !== undefined ?
      this.buildDebugVpnConfig(this.desiredConfig, options.trustedApplication) : this.desiredConfig;
    this.resetTunRuntimeStats();
    return this.createVpnWithTimeout(config, options.timeoutMs);
  }

  markReconfiguredVpnReady(tunFd: number): void {
    const platform = this.parseEnvelope(
      netbird.coreSetPlatformState(tunFd, true, true, true, true, ''));
    if (!platform.ok) {
      throw new Error(platform.message ?? 'Harmony recreated VPN platform state update failed');
    }
  }

  async waitForVersionedFdConsumption(lease: VpnReconfigurationLease,
    timeoutMs: number): Promise<HarmonyPlatformSummary> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const snapshot = this.readSnapshot();
      this.applyDesiredSnapshot(snapshot);
      if (snapshot.reconfigurationGeneration !== lease.generation ||
        snapshot.preparationGeneration !== lease.preparationGeneration ||
        snapshot.configRevision !== lease.configRevision) {
        throw new Error('Harmony recreated fd lease changed before consumption');
      }
      // A matching consume atomically clears the target revision and moves the
      // reconfiguration state to stable. Accept that terminal snapshot before
      // enforcing the in-flight target lease.
      if (snapshot.preparationState === 'fd-consumed' &&
        snapshot.appliedConfigRevision === lease.configRevision &&
        snapshot.reconfigurationState === 'stable') {
        return this.summary();
      }
      if (snapshot.reconfigurationTargetRevision !== lease.targetRevision) {
        throw new Error('Harmony recreated fd lease changed before consumption');
      }
      if (snapshot.reconfigurationState === 'failed' ||
        snapshot.reconfigurationState === 'rolled-back' ||
        snapshot.preparationState === 'cancelled' || snapshot.preparationState === 'rolled-back') {
        throw new Error('Harmony recreated fd consumption stopped');
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 50));
    }
    throw new Error('Harmony recreated fd consumption timed out');
  }

  resetTunRuntimeStats(): HarmonyPlatformSummary {
    const reset = JSON.parse(netbird.coreResetTunRuntimeStats()) as TunRuntimeEnvelope;
    if (!reset.ok) {
      throw new Error(reset.message ?? 'Harmony TUN runtime stats could not be reset');
    }
    this.tunRuntimeStats = reset.data ?? this.tunRuntimeStats;
    return this.summary();
  }

  refreshTunRuntimeStats(): HarmonyPlatformSummary {
    const envelope = JSON.parse(netbird.coreTunRuntimeStats()) as TunRuntimeEnvelope;
    if (!envelope.ok || envelope.data === undefined) {
      throw new Error(envelope.message ?? 'Harmony TUN runtime stats unavailable');
    }
    this.tunRuntimeStats = envelope.data;
    return this.summary();
  }

  async rollback(): Promise<void> {
    if (this.rollbackTask !== undefined) {
      return this.rollbackTask;
    }
    if (this.platformState === HarmonyPlatformState.STOPPED) {
      return;
    }
    this.rollbackTask = this.performRollback();
    return this.rollbackTask;
  }

  runNoVpnSelfTest(): string {
    const nativeResult = this.parseEnvelope(netbird.corePlatformSelfTest());
    if (!nativeResult.ok) {
      throw new Error(nativeResult.message ?? 'native platform adapter self-test failed');
    }
    const synthetic: HarmonyDesiredSnapshot = {
      revision: 5,
      interfaceRevision: 1,
      preparationGeneration: 1,
      preparationState: 'awaiting-fd',
      configRevision: 5,
      appliedConfigRevision: 0,
      reconfigurationGeneration: 0,
      reconfigurationState: 'idle',
      reconfigurationTargetRevision: 0,
      interfacesReady: true,
      configReady: true,
      addresses: ['100.64.0.10/16', '2001:db8:1::10/64'],
      routes: ['10.0.0.0/8', '2001:db8:2::/64'],
      dnsAddresses: ['100.64.0.53'],
      searchDomains: ['example.test'],
      mtu: 1280
    };
    const model = this.buildVpnConfig(synthetic);
    // Two snapshot routes plus the two fake IP blocks the tunnel always carries.
    const expectedRoutes = synthetic.routes.length + 2;
    if (model.addresses.length !== 2 || model.routes?.length !== expectedRoutes || model.mtu !== 1280 ||
      model.isIPv4Accepted !== true || model.isIPv6Accepted !== true ||
      !model.routes.some((route: connection.RouteInfo) =>
        route.destination.address.address === '240.0.0.0' && route.destination.prefixLength === 8)) {
      throw new Error('in-memory VpnConfig validation failed');
    }
    const debugModel = this.buildDebugVpnConfig(model, 'org.huangedehw.nbconnect');
    if (debugModel.trustedApplications?.length !== 1 ||
      debugModel.trustedApplications[0] !== 'org.huangedehw.nbconnect' ||
      !debugModel.routes?.some((route: connection.RouteInfo) =>
        route.destination.address.address === '0.0.0.0' && route.destination.prefixLength === 0)) {
      throw new Error('debug real VPN config gate validation failed');
    }
    return 'NetworkKit interfaces OK; Go platform snapshot OK; in-memory VpnConfig OK; ' +
      'debug real VPN config gate OK; late-fd wait/provide/cancel OK; generation-safe reconfiguration OK; ' +
      'stale lease rejection OK; idempotent rollback OK; VPN_CREATE_DISABLED; NB_RECONFIGURATION_SELFTEST_DONE; ' +
      'NB_LATE_FD_SELFTEST_DONE; NB_PLATFORM_BRIDGE_SELFTEST_DONE';
  }

  private async registerNetworkObserver(): Promise<void> {
    if (this.observer !== undefined) {
      return;
    }
    const observer = connection.createNetConnection();
    observer.on('netAvailable', (_handle: connection.NetHandle) => this.scheduleInterfaceRefresh());
    observer.on('netLost', (_handle: connection.NetHandle) => this.scheduleInterfaceRefresh());
    observer.on('netCapabilitiesChange', (_info: connection.NetCapabilityInfo) => this.scheduleInterfaceRefresh());
    observer.on('netConnectionPropertiesChange', (_info: connection.NetConnectionPropertyInfo) =>
      this.scheduleInterfaceRefresh());
    observer.on('netUnavailable', () => this.scheduleInterfaceRefresh());
    await new Promise<void>((resolve, reject) => {
      observer.register((error: BusinessError) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          reject(new Error(`NetworkKit observer registration failed: ${error.code}`));
          return;
        }
        resolve();
      });
    });
    this.observer = observer;
  }

  private async unregisterNetworkObserver(): Promise<void> {
    const observer = this.observer;
    this.observer = undefined;
    if (observer === undefined) {
      return;
    }
    await new Promise<void>((resolve) => {
      observer.unregister((_error: BusinessError) => resolve());
    });
  }

  private scheduleInterfaceRefresh(): void {
    if (this.platformState === HarmonyPlatformState.ROLLING_BACK ||
      this.platformState === HarmonyPlatformState.STOPPED) {
      return;
    }
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = -1;
      this.refreshPhysicalInterfaces().catch(() => {
        this.platformState = HarmonyPlatformState.ERROR;
      });
    }, 150);
  }

  private async refreshPhysicalInterfaces(): Promise<void> {
    if (this.refreshRunning) {
      return;
    }
    this.refreshRunning = true;
    try {
      const handles = await connection.getAllNets();
      const interfacesByName = new Map<string, PhysicalInterface>();
      for (const handle of handles) {
        try {
          const capabilities = await connection.getNetCapabilities(handle);
          if (capabilities.networkCap === undefined ||
            capabilities.networkCap.indexOf(connection.NetCap.NET_CAPABILITY_NOT_VPN) < 0) {
            continue;
          }
          const properties = await connection.getConnectionProperties(handle);
          const name = properties.interfaceName;
          if (name.length === 0 || name === 'lo' || properties.mtu <= 0) {
            continue;
          }
          let item = interfacesByName.get(name);
          if (item === undefined) {
            item = {
              name: name,
              index: handle.netId,
              mtu: properties.mtu,
              up: true,
              broadcast: true,
              loopback: false,
              pointToPoint: false,
              multicast: true,
              addresses: []
            };
            interfacesByName.set(name, item);
          } else if (handle.netId < item.index) {
            item.index = handle.netId;
          }
          for (const linkAddress of properties.linkAddresses) {
            const address = linkAddress.address.address.trim();
            if (address.length === 0) {
              continue;
            }
            const prefix = `${address}/${linkAddress.prefixLength}`;
            if (item.addresses.indexOf(prefix) < 0) {
              item.addresses.push(prefix);
            }
          }
        } catch (_) {
          // A network can disappear between getAllNets and property lookup.
        }
      }

      const interfaces = Array.from(interfacesByName.values())
        .filter((item: PhysicalInterface) => item.addresses.length > 0)
        .sort((left: PhysicalInterface, right: PhysicalInterface) => left.name.localeCompare(right.name));
      for (const item of interfaces) {
        item.addresses.sort();
      }
      if (interfaces.length === 0) {
        throw new Error('NetworkKit returned no usable non-VPN physical interfaces');
      }

      const envelope = this.parseEnvelope(netbird.coreSetInterfaces(JSON.stringify({ interfaces: interfaces } as PhysicalInterfaceSet)));
      if (!envelope.ok) {
        throw new Error(envelope.message ?? 'Go rejected NetworkKit interfaces');
      }
      this.interfaceCount = interfaces.length;
      const snapshot = this.readSnapshot();
      this.interfaceRevision = snapshot.interfaceRevision;
    } finally {
      this.refreshRunning = false;
    }
  }

  private startSnapshotPolling(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval(() => this.pullDesiredSnapshot(), 250);
  }

  private pullDesiredSnapshot(): void {
    if (this.platformState === HarmonyPlatformState.ROLLING_BACK ||
      this.platformState === HarmonyPlatformState.STOPPED) {
      return;
    }
    try {
      this.applyDesiredSnapshot(this.readSnapshot());
    } catch (_) {
      this.platformState = HarmonyPlatformState.ERROR;
    }
  }

  private applyDesiredSnapshot(snapshot: HarmonyDesiredSnapshot): void {
    this.interfaceRevision = snapshot.interfaceRevision;
    this.preparationGeneration = snapshot.preparationGeneration;
    this.preparationState = snapshot.preparationState;
    this.configRevision = snapshot.configRevision;
    this.appliedConfigRevision = snapshot.appliedConfigRevision;
    this.reconfigurationGeneration = snapshot.reconfigurationGeneration;
    this.reconfigurationState = snapshot.reconfigurationState;
    this.reconfigurationTargetRevision = snapshot.reconfigurationTargetRevision;
    if (snapshot.revision === this.desiredRevision) {
      return;
    }
    this.desiredRevision = snapshot.revision;
    if (snapshot.configReady) {
      this.desiredConfig = this.buildVpnConfig(snapshot);
      this.platformState = HarmonyPlatformState.CONFIGURED;
    } else {
      this.desiredConfig = undefined;
      this.platformState = HarmonyPlatformState.PREPARED;
    }
  }

  private readSnapshot(): HarmonyDesiredSnapshot {
    const envelope = this.parseEnvelope(netbird.corePlatformSnapshot());
    if (!envelope.ok || envelope.data === undefined) {
      throw new Error(envelope.message ?? 'platform snapshot unavailable');
    }
    return envelope.data;
  }

  private buildDebugVpnConfig(config: vpnExtension.VpnConfig, bundleName: string): vpnExtension.VpnConfig {
    const routes = config.routes?.slice() ?? [];
    if (!routes.some((route: connection.RouteInfo) =>
      route.destination.address.address === '0.0.0.0' && route.destination.prefixLength === 0)) {
      routes.push(this.toRoute('0.0.0.0/0'));
    }
    return {
      addresses: config.addresses.slice(),
      routes: routes,
      dnsAddresses: config.dnsAddresses?.slice(),
      searchDomains: config.searchDomains?.slice(),
      mtu: config.mtu,
      isIPv4Accepted: true,
      isIPv6Accepted: config.isIPv6Accepted,
      isInternal: config.isInternal,
      isBlocking: false,
      trustedApplications: [bundleName]
    };
  }

  private buildVpnConfig(snapshot: HarmonyDesiredSnapshot): vpnExtension.VpnConfig {
    // Go 的 nil slice 序列化为 null，例如关闭 DNS 接管后 dnsAddresses 就是 null，
    // 因此这里逐个兜底，避免整个准备流程因为某个空列表而失败。
    const snapshotAddresses = snapshot.addresses ?? [];
    const snapshotRoutes = snapshot.routes ?? [];
    const snapshotDNS = snapshot.dnsAddresses ?? [];
    const snapshotDomains = snapshot.searchDomains ?? [];
    if (!snapshot.configReady || snapshot.mtu <= 0 || snapshotAddresses.length === 0) {
      throw new Error('platform snapshot is not ready for VpnConfig construction');
    }
    const addresses = snapshotAddresses.map((prefix: string) => this.toLinkAddress(prefix));
    const routePrefixes = this.withFakeIPBlocks(snapshotRoutes);
    const routes = routePrefixes.map((prefix: string) => this.toRoute(prefix));
    const ipv4 = snapshotAddresses.some((prefix: string) => prefix.indexOf(':') < 0);
    const ipv6 = snapshotAddresses.some((prefix: string) => prefix.indexOf(':') >= 0);
    return {
      addresses: addresses,
      routes: routes,
      dnsAddresses: snapshotDNS.slice(),
      searchDomains: snapshotDomains.slice(),
      mtu: snapshot.mtu,
      isIPv4Accepted: ipv4,
      isIPv6Accepted: ipv6,
      isInternal: false,
      isBlocking: false
    };
  }

  // The Core answers a domain resource with an address from its fake IP block and
  // translates it back through the userspace firewall. Carrying the whole block in
  // the tunnel from the start means a newly resolved domain never changes the system
  // VPN configuration, so no tunnel rebuild is needed for it. The per-address
  // prefixes the engine keeps in its desired set are dropped here: the block already
  // covers them, and writing them into the system configuration would only add
  // redundant entries that grow with every lookup.
  private withFakeIPBlocks(routes: Array<string>): Array<string> {
    const merged = routes.filter((prefix: string) => !this.isInsideFakeIPBlock(prefix));
    for (const block of [FAKE_IP_V4_BLOCK, FAKE_IP_V6_BLOCK]) {
      if (!merged.includes(block)) {
        merged.push(block);
      }
    }
    return merged;
  }

  private isInsideFakeIPBlock(prefix: string): boolean {
    return prefix.startsWith('240.') || prefix.toLowerCase().startsWith('100:');
  }

  private toLinkAddress(prefix: string): connection.LinkAddress {
    const separator = prefix.lastIndexOf('/');
    if (separator <= 0 || separator === prefix.length - 1) {
      throw new Error('invalid platform address prefix');
    }
    const address = prefix.substring(0, separator);
    const prefixLength = Number.parseInt(prefix.substring(separator + 1), 10);
    if (!Number.isInteger(prefixLength)) {
      throw new Error('invalid platform prefix length');
    }
    return { address: { address: address }, prefixLength: prefixLength };
  }

  private toRoute(prefix: string): connection.RouteInfo {
    const destination = this.toLinkAddress(prefix);
    const ipv6 = destination.address.address.indexOf(':') >= 0;
    return {
      interface: '',
      destination: destination,
      gateway: { address: ipv6 ? '::' : '0.0.0.0' },
      hasGateway: false,
      isDefaultRoute: destination.prefixLength === 0
    };
  }

  private async performRollback(): Promise<void> {
    this.platformState = HarmonyPlatformState.ROLLING_BACK;
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    await this.unregisterNetworkObserver();
    try {
      netbird.corePlatformRollback();
    } catch (_) {
      // Continue local rollback even if the native module is already gone.
    }
    this.desiredConfig = undefined;
    if (this.vpnCreateAttempted || this.vpnCreated) {
      try {
        await this.connection.destroy();
      } catch (_) {
        // create() may reject after a transient system install; destroy remains
        // mandatory and is allowed to report that nothing is left to remove.
      }
      this.vpnCreated = false;
      this.vpnCreateAttempted = false;
    }
    this.platformState = HarmonyPlatformState.STOPPED;
  }

  private parseEnvelope(raw: string): NativeEnvelope {
    return JSON.parse(raw) as NativeEnvelope;
  }

  private summary(): HarmonyPlatformSummary {
    return {
      state: this.platformState,
      interfaceCount: this.interfaceCount,
      interfaceRevision: this.interfaceRevision,
      desiredRevision: this.desiredRevision,
      preparationGeneration: this.preparationGeneration,
      preparationState: this.preparationState,
      configRevision: this.configRevision,
      appliedConfigRevision: this.appliedConfigRevision,
      reconfigurationGeneration: this.reconfigurationGeneration,
      reconfigurationState: this.reconfigurationState,
      reconfigurationTargetRevision: this.reconfigurationTargetRevision,
      configReady: this.desiredConfig !== undefined,
      vpnCreateAttempted: this.vpnCreateAttempted,
      vpnCreated: this.vpnCreated,
      tunNonblockingVerified: this.tunRuntimeStats.nonblockingVerified,
      tunReadPackets: this.tunRuntimeStats.readPackets,
      tunWritePackets: this.tunRuntimeStats.writePackets,
      tunInvalidPackets: this.tunRuntimeStats.invalidPackets
    };
  }
}

class HarmonyAdapterReconfigurationLease implements VpnReconfigurationLease {
  generation: number;
  targetRevision: number;
  preparationGeneration: number;
  configRevision: number;
  appliedConfigRevision: number;
  state: string;

  constructor(summary: HarmonyPlatformSummary, state: string) {
    this.generation = summary.reconfigurationGeneration;
    this.targetRevision = summary.reconfigurationTargetRevision;
    this.preparationGeneration = summary.preparationGeneration;
    this.configRevision = summary.configRevision;
    this.appliedConfigRevision = summary.appliedConfigRevision;
    this.state = state;
  }
}

class HarmonyAdapterReconfigurationLifecycle implements VpnReconfigurationLifecycle {
  private readonly adapter: HarmonyPlatformAdapter;
  private readonly options: HarmonyVpnReconfigurationOptions;
  private activeTunFd: number = -1;

  constructor(adapter: HarmonyPlatformAdapter, options: HarmonyVpnReconfigurationOptions) {
    this.adapter = adapter;
    this.options = options;
  }

  async beginOldFdRelease(request: VpnReconfigurationRequest): Promise<VpnReconfigurationLease> {
    const summary = await this.adapter.beginCoreReconfiguration(
      request.generation, request.targetRevision, this.options.timeoutMs);
    this.notifyPhase('old-fd-released');
    return new HarmonyAdapterReconfigurationLease(summary, 'old-fd-released');
  }

  async destroyOldVpn(): Promise<void> {
    await this.adapter.destroyCurrentVpnForReconfiguration();
    this.notifyPhase('old-vpn-destroyed');
  }

  async restartPreparation(request: VpnReconfigurationRequest): Promise<VpnReconfigurationLease> {
    const summary = await this.adapter.restartCorePreparation(request.generation,
      this.options.stateFilePath, this.options.cacheDir, this.options.logFilePath, this.options.timeoutMs);
    this.notifyPhase('awaiting-new-fd');
    return new HarmonyAdapterReconfigurationLease(summary, 'awaiting-new-fd');
  }

  async createVpn(lease: VpnReconfigurationLease): Promise<number> {
    this.activeTunFd = await this.adapter.createVpnForReconfiguration(lease, this.options);
    this.notifyPhase('new-vpn-created');
    return this.activeTunFd;
  }

  async provideTunFd(tunFd: number, lease: VpnReconfigurationLease): Promise<void> {
    this.adapter.provideCoreTunFDForGeneration(tunFd, lease.preparationGeneration,
      lease.generation, lease.configRevision);
    this.notifyPhase('new-fd-provided');
  }

  async waitTunFdConsumed(lease: VpnReconfigurationLease): Promise<VpnReconfigurationLease> {
    const summary = await this.adapter.waitForVersionedFdConsumption(lease, this.options.timeoutMs);
    this.adapter.markReconfiguredVpnReady(this.activeTunFd);
    this.notifyPhase('new-fd-consumed');
    return new HarmonyAdapterReconfigurationLease(summary, 'fd-consumed');
  }

  async rollback(): Promise<void> {
    await this.adapter.rollback();
  }

  private notifyPhase(phase: string): void {
    if (this.options.phaseObserver !== undefined) {
      this.options.phaseObserver(phase);
    }
  }
}

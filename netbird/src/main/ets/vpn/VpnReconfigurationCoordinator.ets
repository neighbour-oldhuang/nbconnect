export interface VpnReconfigurationRequest {
  generation: number;
  targetRevision: number;
}

export interface VpnReconfigurationLease {
  generation: number;
  targetRevision: number;
  preparationGeneration: number;
  configRevision: number;
  appliedConfigRevision: number;
  state: string;
}

export interface VpnReconfigurationResult {
  generation: number;
  targetRevision: number;
  preparationGeneration: number;
  configRevision: number;
  appliedConfigRevision: number;
}

export interface VpnReconfigurationLifecycle {
  beginOldFdRelease(request: VpnReconfigurationRequest): Promise<VpnReconfigurationLease>;
  destroyOldVpn(): Promise<void>;
  restartPreparation(request: VpnReconfigurationRequest): Promise<VpnReconfigurationLease>;
  createVpn(lease: VpnReconfigurationLease): Promise<number>;
  provideTunFd(tunFd: number, lease: VpnReconfigurationLease): Promise<void>;
  waitTunFdConsumed(lease: VpnReconfigurationLease): Promise<VpnReconfigurationLease>;
  rollback(): Promise<void>;
}

export class VpnReconfigurationCoordinator {
  private active: boolean = false;

  async run(request: VpnReconfigurationRequest,
    lifecycle: VpnReconfigurationLifecycle): Promise<VpnReconfigurationResult> {
    this.validateRequest(request);
    if (this.active) {
      throw new Error('VPN reconfiguration is already active');
    }
    this.active = true;
    try {
      const released = await lifecycle.beginOldFdRelease(request);
      this.validateReleasedLease(request, released);
      await lifecycle.destroyOldVpn();

      const restarted = await lifecycle.restartPreparation(request);
      this.validateRestartedLease(request, restarted);
      const tunFd = await lifecycle.createVpn(restarted);
      if (!Number.isInteger(tunFd) || tunFd <= 0) {
        throw new Error('VPN reconfiguration create returned an invalid fd');
      }
      await lifecycle.provideTunFd(tunFd, restarted);

      const consumed = await lifecycle.waitTunFdConsumed(restarted);
      this.validateConsumedLease(restarted, consumed);
      return {
        generation: consumed.generation,
        targetRevision: restarted.targetRevision,
        preparationGeneration: consumed.preparationGeneration,
        configRevision: consumed.configRevision,
        appliedConfigRevision: consumed.appliedConfigRevision
      };
    } catch (error) {
      try {
        await lifecycle.rollback();
      } catch (_) {
        // Preserve the first lifecycle error; rollback remains best effort here.
      }
      const err = error as Error;
      throw new Error(`VPN reconfiguration failed: ${err.message}`);
    } finally {
      this.active = false;
    }
  }

  private validateRequest(request: VpnReconfigurationRequest): void {
    if (!Number.isInteger(request.generation) || request.generation <= 0 ||
      !Number.isInteger(request.targetRevision) || request.targetRevision <= 0) {
      throw new Error('VPN reconfiguration request is invalid');
    }
  }

  // The engine keeps publishing configuration while it is being restarted, so the
  // Core's target revision advances during the cycle. That is not staleness: the
  // generation identifies the cycle, and a target may only move forward.
  private validateReleasedLease(request: VpnReconfigurationRequest,
    lease: VpnReconfigurationLease): void {
    if (lease.generation !== request.generation || lease.targetRevision < request.targetRevision ||
      lease.state !== 'old-fd-released') {
      throw new Error('VPN old fd release lease is stale ' +
        `(generation=${lease.generation}/${request.generation}, ` +
        `target=${lease.targetRevision}/${request.targetRevision}, state=${lease.state})`);
    }
  }

  private validateRestartedLease(request: VpnReconfigurationRequest,
    lease: VpnReconfigurationLease): void {
    if (lease.generation !== request.generation || lease.targetRevision < request.targetRevision ||
      lease.state !== 'awaiting-new-fd' || lease.preparationGeneration <= 0 ||
      lease.configRevision !== lease.targetRevision || lease.appliedConfigRevision >= lease.configRevision) {
      throw new Error('VPN restarted preparation lease is stale ' +
        `(generation=${lease.generation}/${request.generation}, ` +
        `target=${lease.targetRevision}/${request.targetRevision}, state=${lease.state}, ` +
        `configRevision=${lease.configRevision}, appliedRevision=${lease.appliedConfigRevision})`);
    }
  }

  private validateConsumedLease(expected: VpnReconfigurationLease,
    consumed: VpnReconfigurationLease): void {
    if (consumed.generation !== expected.generation || consumed.targetRevision !== 0 ||
      consumed.preparationGeneration !== expected.preparationGeneration ||
      consumed.configRevision !== expected.configRevision || consumed.state !== 'fd-consumed' ||
      consumed.appliedConfigRevision !== expected.configRevision) {
      throw new Error('VPN consumed fd lease does not match the restarted preparation');
    }
  }
}

class FakeVpnReconfigurationLifecycle implements VpnReconfigurationLifecycle {
  readonly events: string[] = [];
  rollbackCalled: boolean = false;
  destroyOnAttempt: boolean = false;
  private createAttempted: boolean = false;
  private readonly mode: string;

  constructor(mode: string = 'success') {
    this.mode = mode;
  }

  async beginOldFdRelease(request: VpnReconfigurationRequest): Promise<VpnReconfigurationLease> {
    this.events.push('begin');
    if (this.mode === 'release-timeout') {
      throw new Error('synthetic old fd release timeout');
    }
    return {
      generation: this.mode === 'stale-release' ? request.generation + 1 : request.generation,
      targetRevision: request.targetRevision,
      preparationGeneration: 3,
      configRevision: request.targetRevision,
      appliedConfigRevision: request.targetRevision - 1,
      state: 'old-fd-released'
    };
  }

  async destroyOldVpn(): Promise<void> {
    this.events.push('destroy');
    if (this.mode === 'destroy-fail') {
      throw new Error('synthetic destroy failure');
    }
  }

  async restartPreparation(request: VpnReconfigurationRequest): Promise<VpnReconfigurationLease> {
    this.events.push('restart');
    if (this.mode === 'restart-timeout') {
      throw new Error('synthetic restart timeout');
    }
    return {
      generation: request.generation,
      targetRevision: request.targetRevision,
      preparationGeneration: 4,
      configRevision: this.mode === 'stale-restart' ? request.targetRevision + 1 : request.targetRevision,
      appliedConfigRevision: request.targetRevision - 1,
      state: 'awaiting-new-fd'
    };
  }

  async createVpn(_lease: VpnReconfigurationLease): Promise<number> {
    this.events.push('create');
    this.createAttempted = true;
    if (this.mode === 'create-reject') {
      throw new Error('synthetic create rejection');
    }
    if (this.mode === 'invalid-fd') {
      return 0;
    }
    return 42;
  }

  async provideTunFd(_tunFd: number, _lease: VpnReconfigurationLease): Promise<void> {
    this.events.push('provide');
    if (this.mode === 'provide-reject' || this.mode === 'provide-timeout') {
      throw new Error(this.mode === 'provide-timeout' ?
        'synthetic versioned provide timeout' : 'synthetic versioned provide rejection');
    }
  }

  async waitTunFdConsumed(lease: VpnReconfigurationLease): Promise<VpnReconfigurationLease> {
    this.events.push('consume');
    if (this.mode === 'consume-timeout') {
      throw new Error('synthetic consume timeout');
    }
    return {
      generation: lease.generation,
      targetRevision: this.mode === 'consume-target-mismatch' ? lease.targetRevision : 0,
      preparationGeneration: lease.preparationGeneration,
      configRevision: lease.configRevision,
      appliedConfigRevision: this.mode === 'consume-mismatch' ? lease.configRevision - 1 : lease.configRevision,
      state: 'fd-consumed'
    };
  }

  async rollback(): Promise<void> {
    this.events.push('rollback');
    this.rollbackCalled = true;
    if (this.createAttempted) {
      this.destroyOnAttempt = true;
    }
  }
}

async function expectSyntheticFailure(mode: string, requireDestroyOnAttempt: boolean): Promise<void> {
  const coordinator = new VpnReconfigurationCoordinator();
  const lifecycle = new FakeVpnReconfigurationLifecycle(mode);
  let failed = false;
  try {
    await coordinator.run({ generation: 7, targetRevision: 11 }, lifecycle);
  } catch (_) {
    failed = true;
  }
  if (!failed || !lifecycle.rollbackCalled ||
    (requireDestroyOnAttempt && !lifecycle.destroyOnAttempt)) {
    throw new Error(`VPN reconfiguration ${mode} rollback self-test failed`);
  }
}

export async function runVpnReconfigurationCoordinatorSelfTest(): Promise<string> {
  const coordinator = new VpnReconfigurationCoordinator();
  const success = new FakeVpnReconfigurationLifecycle();
  const result = await coordinator.run({ generation: 7, targetRevision: 11 }, success);
  if (result.generation !== 7 || result.configRevision !== 11 || result.appliedConfigRevision !== 11 ||
    success.events.join(',') !== 'begin,destroy,restart,create,provide,consume') {
    throw new Error('VPN reconfiguration success order self-test failed');
  }

  await expectSyntheticFailure('release-timeout', false);
  await expectSyntheticFailure('stale-release', false);
  await expectSyntheticFailure('destroy-fail', false);
  await expectSyntheticFailure('restart-timeout', false);
  await expectSyntheticFailure('stale-restart', false);
  await expectSyntheticFailure('create-reject', true);
  await expectSyntheticFailure('invalid-fd', true);
  await expectSyntheticFailure('provide-reject', true);
  await expectSyntheticFailure('provide-timeout', true);
  await expectSyntheticFailure('consume-timeout', true);
  await expectSyntheticFailure('consume-target-mismatch', true);
  await expectSyntheticFailure('consume-mismatch', true);
  return 'VPN host reconfiguration lifecycle OK; destroy-on-attempt OK; stale lease rejection OK';
}

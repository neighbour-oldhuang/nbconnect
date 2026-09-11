export type VpnExplicitConnectionState =
  'preparing' | 'ready' | 'connecting' | 'connected' | 'disconnecting' | 'disconnected' | 'failed' | 'stopped';

export interface VpnExplicitConnectionLifecycle {
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  rollback(): Promise<void>;
}

export class VpnExplicitConnectionCallbacks implements VpnExplicitConnectionLifecycle {
  private readonly connectAction: () => Promise<void>;
  private readonly disconnectAction: () => Promise<void>;
  private readonly rollbackAction: () => Promise<void>;

  constructor(connectAction: () => Promise<void>, disconnectAction: () => Promise<void>,
    rollbackAction: () => Promise<void>) {
    this.connectAction = connectAction;
    this.disconnectAction = disconnectAction;
    this.rollbackAction = rollbackAction;
  }

  async connect(): Promise<void> {
    await this.connectAction();
  }

  async disconnect(): Promise<void> {
    await this.disconnectAction();
  }

  async rollback(): Promise<void> {
    await this.rollbackAction();
  }
}

export interface VpnExplicitConnectionResult {
  state: VpnExplicitConnectionState;
  changed: boolean;
}

export class VpnExplicitConnectionCoordinator {
  private lifecycleState: VpnExplicitConnectionState = 'preparing';

  get state(): VpnExplicitConnectionState {
    return this.lifecycleState;
  }

  markReady(): void {
    if (this.lifecycleState === 'stopped') {
      throw new Error('VPN connection lifecycle is stopped');
    }
    this.lifecycleState = 'ready';
  }

  markFailed(): void {
    if (this.lifecycleState !== 'stopped') {
      this.lifecycleState = 'failed';
    }
  }

  markStopped(): void {
    this.lifecycleState = 'stopped';
  }

  async connect(lifecycle: VpnExplicitConnectionLifecycle): Promise<VpnExplicitConnectionResult> {
    if (this.lifecycleState === 'connected') {
      return { state: this.lifecycleState, changed: false };
    }
    if (this.lifecycleState !== 'ready' && this.lifecycleState !== 'disconnected' &&
      this.lifecycleState !== 'failed') {
      throw new Error(`VPN connection cannot start from ${this.lifecycleState}`);
    }
    this.lifecycleState = 'connecting';
    try {
      await lifecycle.connect();
      this.lifecycleState = 'connected';
      return { state: this.lifecycleState, changed: true };
    } catch (error) {
      try {
        await lifecycle.rollback();
      } catch (_) {
      }
      this.lifecycleState = 'failed';
      const err = error as Error;
      throw new Error(`VPN connect failed: ${err.message}`);
    }
  }

  async disconnect(lifecycle: VpnExplicitConnectionLifecycle): Promise<VpnExplicitConnectionResult> {
    if (this.lifecycleState === 'disconnected') {
      return { state: this.lifecycleState, changed: false };
    }
    if (this.lifecycleState === 'stopped') {
      return { state: this.lifecycleState, changed: false };
    }
    if (this.lifecycleState === 'preparing' || this.lifecycleState === 'connecting' ||
      this.lifecycleState === 'disconnecting') {
      throw new Error(`VPN connection cannot stop from ${this.lifecycleState}`);
    }
    this.lifecycleState = 'disconnecting';
    try {
      await lifecycle.disconnect();
      this.lifecycleState = 'disconnected';
      return { state: this.lifecycleState, changed: true };
    } catch (error) {
      try {
        await lifecycle.rollback();
      } catch (_) {
      }
      this.lifecycleState = 'failed';
      const err = error as Error;
      throw new Error(`VPN disconnect failed: ${err.message}`);
    }
  }
}

class FakeExplicitConnectionLifecycle implements VpnExplicitConnectionLifecycle {
  connectCount: number = 0;
  disconnectCount: number = 0;
  rollbackCount: number = 0;
  failConnect: boolean = false;
  failDisconnect: boolean = false;

  async connect(): Promise<void> {
    this.connectCount++;
    if (this.failConnect) {
      throw new Error('synthetic connect failure');
    }
  }

  async disconnect(): Promise<void> {
    this.disconnectCount++;
    if (this.failDisconnect) {
      throw new Error('synthetic disconnect failure');
    }
  }

  async rollback(): Promise<void> {
    this.rollbackCount++;
  }
}

export async function runVpnExplicitConnectionCoordinatorSelfTest(): Promise<string> {
  const coordinator = new VpnExplicitConnectionCoordinator();
  const lifecycle = new FakeExplicitConnectionLifecycle();
  coordinator.markReady();
  const connected = await coordinator.connect(lifecycle);
  const duplicateConnect = await coordinator.connect(lifecycle);
  const disconnected = await coordinator.disconnect(lifecycle);
  const duplicateDisconnect = await coordinator.disconnect(lifecycle);
  const reconnected = await coordinator.connect(lifecycle);
  if (connected.state !== 'connected' || !connected.changed || duplicateConnect.changed ||
    disconnected.state !== 'disconnected' || !disconnected.changed || duplicateDisconnect.changed ||
    reconnected.state !== 'connected' || lifecycle.connectCount !== 2 || lifecycle.disconnectCount !== 1) {
    throw new Error('VPN explicit connection lifecycle success/idempotency self-test failed');
  }

  const connectFailure = new VpnExplicitConnectionCoordinator();
  const connectFailureLifecycle = new FakeExplicitConnectionLifecycle();
  connectFailureLifecycle.failConnect = true;
  connectFailure.markReady();
  let connectFailed = false;
  try {
    await connectFailure.connect(connectFailureLifecycle);
  } catch (_) {
    connectFailed = true;
  }
  if (!connectFailed || connectFailure.state !== 'failed' || connectFailureLifecycle.rollbackCount !== 1) {
    throw new Error('VPN explicit connection connect rollback self-test failed');
  }

  const disconnectFailure = new VpnExplicitConnectionCoordinator();
  const disconnectFailureLifecycle = new FakeExplicitConnectionLifecycle();
  disconnectFailure.markReady();
  await disconnectFailure.connect(disconnectFailureLifecycle);
  disconnectFailureLifecycle.failDisconnect = true;
  let disconnectFailed = false;
  try {
    await disconnectFailure.disconnect(disconnectFailureLifecycle);
  } catch (_) {
    disconnectFailed = true;
  }
  if (!disconnectFailed || disconnectFailure.state !== 'failed' ||
    disconnectFailureLifecycle.rollbackCount !== 1) {
    throw new Error('VPN explicit connection disconnect rollback self-test failed');
  }
  return 'VPN explicit connect/disconnect lifecycle OK; idempotency OK; rollback OK';
}

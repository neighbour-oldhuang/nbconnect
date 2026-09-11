export const coreInit: (deviceName: string, osVersion: string, configJson: string) => string;
export const coreStorePrivateCredentialImport: (credentialFilePath: string, setupKey: string,
  managementUrl: string, managementDialAddress: string) => string;
export const coreStartPrivateAuthentication: (deviceName: string, osVersion: string,
  configFilePath: string, credentialFilePath: string) => string;
export const coreStartSSOLogin: (deviceName: string, osVersion: string,
  configFilePath: string, managementUrl: string, preferDeviceCode: boolean) => string;
export const coreSetClientSettings: (settingsJson: string) => string;
export const coreCancelSSOLogin: () => string;
export const coreSetConfig: (configJson: string) => string;
export const coreSetPlatformState: (tunFd: number, vpnExtensionReady: boolean,
  processProtectReady: boolean, dnsReady: boolean, networkChangeReady: boolean,
  lastError: string) => string;
export const coreClearPlatformState: () => string;
export const coreSetInterfaces: (interfacesJson: string) => string;
export const corePlatformSnapshot: () => string;
export const coreStartPreparation: (stateFilePath: string, cacheDir: string, logFilePath: string) => string;
export const coreProvideTunFD: (tunFd: number) => string;
export const coreDebugRequestReconfiguration: () => string;
export const coreBeginReconfiguration: (generation: number, targetRevision: number) => string;
export const coreRestartPreparation: (generation: number, stateFilePath: string,
  cacheDir: string, logFilePath: string) => string;
export const coreProvideTunFDForGeneration: (tunFd: number, preparationGeneration: number,
  reconfigurationGeneration: number, configRevision: number) => string;
export const corePlatformRollback: () => string;
export const corePlatformSelfTest: () => string;
export const coreStatus: () => string;
export const coreConnect: () => string;
export const coreShutdown: () => string;
export const coreTunSelfTest: () => string;
export const coreResetTunRuntimeStats: () => string;
export const coreTunRuntimeStats: () => string;
export const coreSelfTest: () => string;

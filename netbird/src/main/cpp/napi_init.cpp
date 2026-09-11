#include "napi/native_api.h"
#include "libnbharmony.h"

#include <cstdint>
#include <string>
#include <vector>

static std::string ReadUtf8(napi_env env, napi_value value)
{
    napi_valuetype type = napi_undefined;
    if (value == nullptr || napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return "";
    }

    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return "";
    }

    std::vector<char> buffer(length + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length) != napi_ok) {
        return "";
    }
    return std::string(buffer.data(), length);
}

static int32_t ReadInt32(napi_env env, napi_value value, int32_t fallback)
{
    int32_t result = fallback;
    if (value != nullptr) {
        napi_get_value_int32(env, value, &result);
    }
    return result;
}


static uint64_t ReadUint64(napi_env env, napi_value value, uint64_t fallback)
{
    int64_t result = -1;
    if (value == nullptr || napi_get_value_int64(env, value, &result) != napi_ok || result < 0) {
        return fallback;
    }
    return static_cast<uint64_t>(result);
}

static bool ReadBool(napi_env env, napi_value value)
{
    bool result = false;
    if (value != nullptr) {
        napi_get_value_bool(env, value, &result);
    }
    return result;
}

static napi_value ToArkString(napi_env env, char *goString)
{
    const char *text = goString != nullptr
        ? goString
        : "{\"ok\":false,\"code\":-1,\"message\":\"Go returned null\"}";
    napi_value result;
    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &result);
    if (goString != nullptr) {
        NbFreeString(goString);
    }
    return result;
}

static napi_value CoreInit(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    const std::string deviceName = argc > 0 ? ReadUtf8(env, argv[0]) : "";
    const std::string osVersion = argc > 1 ? ReadUtf8(env, argv[1]) : "";
    const std::string configJson = argc > 2 ? ReadUtf8(env, argv[2]) : "{}";

    return ToArkString(env, NbCoreInit(
        const_cast<char *>(deviceName.c_str()),
        const_cast<char *>(osVersion.c_str()),
        const_cast<char *>(configJson.c_str())));
}

static napi_value CoreStorePrivateCredentialImport(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = { nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const std::string credentialPath = argc > 0 ? ReadUtf8(env, argv[0]) : "";
    const std::string setupKey = argc > 1 ? ReadUtf8(env, argv[1]) : "";
    const std::string managementUrl = argc > 2 ? ReadUtf8(env, argv[2]) : "";
    const std::string managementDialAddress = argc > 3 ? ReadUtf8(env, argv[3]) : "";
    return ToArkString(env, NbCoreStorePrivateCredentialImport(
        const_cast<char *>(credentialPath.c_str()),
        const_cast<char *>(setupKey.c_str()),
        const_cast<char *>(managementUrl.c_str()),
        const_cast<char *>(managementDialAddress.c_str())));
}

static napi_value CoreStartPrivateAuthentication(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = { nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const std::string deviceName = argc > 0 ? ReadUtf8(env, argv[0]) : "";
    const std::string osVersion = argc > 1 ? ReadUtf8(env, argv[1]) : "";
    const std::string configPath = argc > 2 ? ReadUtf8(env, argv[2]) : "";
    const std::string credentialPath = argc > 3 ? ReadUtf8(env, argv[3]) : "";
    return ToArkString(env, NbCoreStartPrivateAuthentication(
        const_cast<char *>(deviceName.c_str()),
        const_cast<char *>(osVersion.c_str()),
        const_cast<char *>(configPath.c_str()),
        const_cast<char *>(credentialPath.c_str())));
}

static napi_value CoreSetConfig(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const std::string configJson = argc > 0 ? ReadUtf8(env, argv[0]) : "";
    return ToArkString(env, NbCoreSetConfig(const_cast<char *>(configJson.c_str())));
}

static napi_value CoreSetPlatformState(napi_env env, napi_callback_info info)
{
    size_t argc = 6;
    napi_value argv[6] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    const int32_t tunFd = argc > 0 ? ReadInt32(env, argv[0], -1) : -1;
    const bool extensionReady = argc > 1 && ReadBool(env, argv[1]);
    const bool processProtectReady = argc > 2 && ReadBool(env, argv[2]);
    const bool dnsReady = argc > 3 && ReadBool(env, argv[3]);
    const bool networkChangeReady = argc > 4 && ReadBool(env, argv[4]);
    const std::string lastError = argc > 5 ? ReadUtf8(env, argv[5]) : "";

    return ToArkString(env, NbCoreSetPlatformState(
        tunFd,
        extensionReady ? 1 : 0,
        processProtectReady ? 1 : 0,
        dnsReady ? 1 : 0,
        networkChangeReady ? 1 : 0,
        const_cast<char *>(lastError.c_str())));
}

static napi_value CoreClearPlatformState(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreClearPlatformState());
}

static napi_value CoreSetInterfaces(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const std::string interfacesJson = argc > 0 ? ReadUtf8(env, argv[0]) : "";
    return ToArkString(env, NbCoreSetInterfaces(const_cast<char *>(interfacesJson.c_str())));
}

static napi_value CorePlatformSnapshot(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCorePlatformSnapshot());
}

static napi_value CoreStartPreparation(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const std::string statePath = argc > 0 ? ReadUtf8(env, argv[0]) : "";
    const std::string cacheDir = argc > 1 ? ReadUtf8(env, argv[1]) : "";
    const std::string logPath = argc > 2 ? ReadUtf8(env, argv[2]) : "";
    return ToArkString(env, NbCoreStartPreparation(
        const_cast<char *>(statePath.c_str()),
        const_cast<char *>(cacheDir.c_str()),
        const_cast<char *>(logPath.c_str())));
}

static napi_value CoreProvideTunFD(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const int32_t tunFd = argc > 0 ? ReadInt32(env, argv[0], -1) : -1;
    return ToArkString(env, NbCoreProvideTunFD(tunFd));
}

static napi_value CoreDebugRequestReconfiguration(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreDebugRequestReconfiguration());
}

static napi_value CoreBeginReconfiguration(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const uint64_t generation = argc > 0 ? ReadUint64(env, argv[0], 0) : 0;
    const uint64_t targetRevision = argc > 1 ? ReadUint64(env, argv[1], 0) : 0;
    return ToArkString(env, NbCoreBeginReconfiguration(generation, targetRevision));
}

static napi_value CoreRestartPreparation(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = { nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const uint64_t generation = argc > 0 ? ReadUint64(env, argv[0], 0) : 0;
    const std::string statePath = argc > 1 ? ReadUtf8(env, argv[1]) : "";
    const std::string cacheDir = argc > 2 ? ReadUtf8(env, argv[2]) : "";
    const std::string logPath = argc > 3 ? ReadUtf8(env, argv[3]) : "";
    return ToArkString(env, NbCoreRestartPreparation(
        generation,
        const_cast<char *>(statePath.c_str()),
        const_cast<char *>(cacheDir.c_str()),
        const_cast<char *>(logPath.c_str())));
}

static napi_value CoreProvideTunFDForGeneration(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = { nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const int32_t tunFd = argc > 0 ? ReadInt32(env, argv[0], -1) : -1;
    const uint64_t preparationGeneration = argc > 1 ? ReadUint64(env, argv[1], 0) : 0;
    const uint64_t reconfigurationGeneration = argc > 2 ? ReadUint64(env, argv[2], 0) : 0;
    const uint64_t configRevision = argc > 3 ? ReadUint64(env, argv[3], 0) : 0;
    return ToArkString(env, NbCoreProvideTunFDForGeneration(
        tunFd, preparationGeneration, reconfigurationGeneration, configRevision));
}

static napi_value CorePlatformRollback(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCorePlatformRollback());
}

static napi_value CorePlatformSelfTest(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCorePlatformSelfTest());
}

static napi_value CoreStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreStatus());
}

static napi_value CoreConnect(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreConnect());
}

static napi_value CoreShutdown(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreShutdown());
}

static napi_value CoreTunSelfTest(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreTunSelfTest());
}

static napi_value CoreResetTunRuntimeStats(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreResetTunRuntimeStats());
}

static napi_value CoreTunRuntimeStats(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreTunRuntimeStats());
}

static napi_value CoreSelfTest(napi_env env, napi_callback_info info)
{
    (void)info;
    return ToArkString(env, NbCoreSelfTest());
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        { "coreInit", nullptr, CoreInit, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreStorePrivateCredentialImport", nullptr, CoreStorePrivateCredentialImport, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreStartPrivateAuthentication", nullptr, CoreStartPrivateAuthentication, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreSetConfig", nullptr, CoreSetConfig, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreSetPlatformState", nullptr, CoreSetPlatformState, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreClearPlatformState", nullptr, CoreClearPlatformState, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreSetInterfaces", nullptr, CoreSetInterfaces, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "corePlatformSnapshot", nullptr, CorePlatformSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreStartPreparation", nullptr, CoreStartPreparation, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreProvideTunFD", nullptr, CoreProvideTunFD, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreDebugRequestReconfiguration", nullptr, CoreDebugRequestReconfiguration, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreBeginReconfiguration", nullptr, CoreBeginReconfiguration, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreRestartPreparation", nullptr, CoreRestartPreparation, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreProvideTunFDForGeneration", nullptr, CoreProvideTunFDForGeneration, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "corePlatformRollback", nullptr, CorePlatformRollback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "corePlatformSelfTest", nullptr, CorePlatformSelfTest, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreStatus", nullptr, CoreStatus, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreConnect", nullptr, CoreConnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreShutdown", nullptr, CoreShutdown, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreTunSelfTest", nullptr, CoreTunSelfTest, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreResetTunRuntimeStats", nullptr, CoreResetTunRuntimeStats, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreTunRuntimeStats", nullptr, CoreTunRuntimeStats, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "coreSelfTest", nullptr, CoreSelfTest, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
EXTERN_C_END

static napi_module netbirdModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "netbird",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterNetbirdModule(void)
{
    napi_module_register(&netbirdModule);
}

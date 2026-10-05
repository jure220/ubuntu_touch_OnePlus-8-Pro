/*
 * Stub android.system.net.netd@1.1::INetd for Halium.
 *
 * Qualcomm's netmgrd will not finish initialising until an INetd HIDL service
 * exists: its main thread waits in NetmgrNetdClient::getInstance() for the
 * service to register.  Until it does, netmgrd never posts its "is complete"
 * event and so never opens /dev/socket/netmgr/netmgr_connect_socket, which is
 * the socket libdsi_netctrl (inside the RIL) must reach before any data call
 * can be set up.  Halium ships no netd, so mobile data was dead.
 *
 * On Android, netd uses this interface to give vendor daemons "OEM networks":
 * extra routing tables selected by a packet mark.  Ubuntu Touch does not route
 * through netd -- ofono and NetworkManager configure the data interface
 * themselves -- so these calls have nothing to act on.  Every call is logged
 * (tag netd-stub) and reported as successful, so netmgrd carries on as it
 * would on Android.  createOemNetwork hands out distinct handles in the same
 * form real netd uses (system/netd NetdHwService.cpp: netIds 1..50 from
 * NetworkController::MIN/MAX_OEM_ID, encoded by netIdToNetHandle as
 * netId << 32 | kHandleMagic, 0xcafed00d), with packet mark 0 because no
 * routing table stands behind them.
 */
#define LOG_TAG "netd-stub"

#include <atomic>

#include <android/system/net/netd/1.1/INetd.h>
#include <hidl/HidlTransportSupport.h>
#include <log/log.h>

using android::sp;
using android::hardware::configureRpcThreadpool;
using android::hardware::hidl_string;
using android::hardware::joinRpcThreadpool;
using android::hardware::Return;
using android::system::net::netd::V1_1::INetd;
using StatusCode = android::system::net::netd::V1_0::INetd::StatusCode;

namespace {

class NetdStub : public INetd {
  public:
    // @1.0
    Return<void> createOemNetwork(createOemNetwork_cb cb) override {
        unsigned netId = mNextNetId++;
        if (netId > kMaxOemId) {
            ALOGE("createOemNetwork: out of OEM netIds (stub)");
            cb(0, 0, StatusCode::UNKNOWN_ERROR);
            return {};
        }
        uint64_t handle = (static_cast<uint64_t>(netId) << 32) | 0xcafed00d;
        ALOGI("createOemNetwork -> netId %u handle 0x%llx (stub)", netId,
              (unsigned long long)handle);
        cb(handle, 0, StatusCode::OK);
        return {};
    }
    Return<StatusCode> destroyOemNetwork(uint64_t h) override {
        ALOGI("destroyOemNetwork %llu (stub)", (unsigned long long)h);
        return StatusCode::OK;
    }

    // @1.1
    Return<StatusCode> addRouteToOemNetwork(uint64_t h, const hidl_string& ifname,
                                            const hidl_string& dst,
                                            const hidl_string& nexthop) override {
        ALOGI("addRouteToOemNetwork %llu %s %s via %s (stub)", (unsigned long long)h,
              ifname.c_str(), dst.c_str(), nexthop.c_str());
        return StatusCode::OK;
    }
    Return<StatusCode> removeRouteFromOemNetwork(uint64_t h, const hidl_string& ifname,
                                                 const hidl_string& dst,
                                                 const hidl_string& nexthop) override {
        ALOGI("removeRouteFromOemNetwork %llu %s %s via %s (stub)", (unsigned long long)h,
              ifname.c_str(), dst.c_str(), nexthop.c_str());
        return StatusCode::OK;
    }
    Return<StatusCode> addInterfaceToOemNetwork(uint64_t h, const hidl_string& ifname) override {
        ALOGI("addInterfaceToOemNetwork %llu %s (stub)", (unsigned long long)h, ifname.c_str());
        return StatusCode::OK;
    }
    Return<StatusCode> removeInterfaceFromOemNetwork(uint64_t h,
                                                     const hidl_string& ifname) override {
        ALOGI("removeInterfaceFromOemNetwork %llu %s (stub)", (unsigned long long)h,
              ifname.c_str());
        return StatusCode::OK;
    }
    Return<StatusCode> setIpForwardEnable(bool enable) override {
        ALOGI("setIpForwardEnable %d (stub)", enable);
        return StatusCode::OK;
    }
    Return<StatusCode> setForwardingBetweenInterfaces(const hidl_string& in,
                                                      const hidl_string& out,
                                                      bool enable) override {
        ALOGI("setForwardingBetweenInterfaces %s -> %s %d (stub)", in.c_str(), out.c_str(),
              enable);
        return StatusCode::OK;
    }

  private:
    static constexpr unsigned kMaxOemId = 50;
    std::atomic<unsigned> mNextNetId{1};
};

}  // namespace

int main() {
    configureRpcThreadpool(1, true /* callerWillJoin */);
    sp<INetd> service = new NetdStub();
    if (service->registerAsService() != android::OK) {
        ALOGE("could not register android.system.net.netd@1.1::INetd/default");
        return 1;
    }
    ALOGI("android.system.net.netd@1.1::INetd/default registered (stub)");
    joinRpcThreadpool();
    return 1;
}

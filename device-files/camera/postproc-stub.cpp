/*
 * Stub replacement for vendor.qti.hardware.camera.postproc@1.0-service-impl.so
 *
 * WHAT THIS IS: a WORKAROUND for an Android 14 / Android 11 vendor ABI clash.
 *
 * WHY
 * vendor.camera-provider-2-4 aborts on EVERY start, ~every 5 s, so no camera
 * can ever open. Tombstone:
 *
 *   Abort message: 'Binder threadpool cannot be shrunk after starting'
 *   #03 libhidlbase  ProcessState::setThreadPoolConfiguration()
 *   #04 libhidlbase  configureBinderRpcThreadpool()
 *   #05 postproc@1.0-service-impl.so  RegisterIPostProcService()
 *   #06 com.qti.chi.override.so       ExtensionModule::GetInstance()
 *   #08 camera.qcom.so                CamX::HAL3Module::GetInstance()
 *   #09 camera.qcom.so                CamX::get_number_of_cameras()
 *   #20 android.hardware.camera.provider@2.4-service_64 (main)
 *
 * The provider's main() configures the binder threadpool, then Qualcomm's CHI
 * extension calls configureBinderRpcThreadpool() again with a SMALLER count.
 * Android 14's libhidlbase added LOG_ALWAYS_FATAL for shrinking a started pool;
 * this Android 11-era vendor blob predates that assertion, so it dies.
 *
 * The real library exports exactly two symbols, so a stub is exact:
 *   _Z24RegisterIPostProcServicev   (RegisterIPostProcService())
 *   __cfi_check
 * com.qti.chi.override.so pulls it in via DT_NEEDED, so the loader is satisfied
 * by any library exporting those names.
 *
 * COST: Qualcomm's camera post-processing service is not registered. That is an
 * offload path for extras (HDR/bokeh style processing); basic camera enumeration
 * and capture do not require it. If the camera works after this, the trade is
 * losing post-processing features rather than having no camera at all.
 *
 * PROPER FIX would be a vendor blob built against Android 14's libhidlbase, or
 * the provider configuring its threadpool so the later call is not a shrink.
 * Neither is available to us.
 *
 * REVERT: the original is saved at /userdata/camera-backup/. Restore it into
 * /android/vendor/lib64/ (overlay upperdir /userdata/vlib-upper, persistent).
 *
 * Built freestanding: no headers, no libc, so no bionic sysroot is needed.
 */

/* Mangles to _Z24RegisterIPostProcServicev -- must NOT be extern "C". */
void RegisterIPostProcService();
void RegisterIPostProcService()
{
	/* Deliberately empty: skipping the threadpool reconfiguration is the
	 * entire point. */
}

/* CFI cross-DSO entry point. com.qti.chi.override.so is CFI-instrumented and
 * will call this for calls landing in this library. Returning normally means
 * "allowed", which is what we want. */
/* MUST be 4096-byte aligned. bionic's linker rejects the whole library
 * otherwise, and the failure surfaces confusingly on the CONSUMER:
 *   LibMap() dlopen failed: unaligned __cfi_check in the library ""
 *            on '/vendor/lib64/hw/com.qti.chi.override.so'
 *   HAL3Module() Couldn't open CHI Module lib.
 * CamX then falls back to the non-CHI path, which enumerates ZERO cameras even
 * though the kernel probed all five sensors successfully. */
extern "C" __attribute__((aligned(4096))) void __cfi_check(unsigned long CallSiteTypeId, void *TargetAddr, void *DiagData);
extern "C" __attribute__((aligned(4096))) void __cfi_check(unsigned long CallSiteTypeId, void *TargetAddr, void *DiagData)
{
	(void)CallSiteTypeId;
	(void)TargetAddr;
	(void)DiagData;
}

# TrueWatch RUM · React Native Dual-Platform Integration Guide

This guide is for developers setting up a TrueWatch RUM (Real User Monitoring) React Native environment from scratch, covering **both iOS and Android**. The goal is a follow-along, step-by-step path that gets everything working: views with real screen names, user actions, network resources, errors, sessions, and Session Replay.

The official documentation is organized by feature; each page is correct on its own, but there is no single "from empty project to full dual-platform functionality" thread. This guide provides that thread, and flags the practical pitfalls at each step.

- Applicable versions: React Native 0.74, `@cloudcare/react-native-mobile` 0.4.2, `@cloudcare/react-native-session-replay` 0.4.x
- Reporting method: public DataWay (`datawayUrl` + `clientToken`, no self-hosted DataKit required)
- The `clientToken`, `appId`, and `datawayUrl` in this guide are placeholders; replace them with the real values obtained from the TrueWatch console

---

## Overview: Full Step Map

1. Create two applications (Android and iOS) in the TrueWatch console and obtain the integration credentials
2. Prepare the React Native project and navigation dependencies
3. Install the RUM SDK and link the native modules
4. Write a unified initialization module (shared by both platforms)
5. Wire the initialization into the app entry point
6. Integrate the view tracking adapter
7. Configure the Android Maven repository (source of native dependencies, mandatory)
8. Integrate Session Replay (including the Android ft-plugin)
9. Build and run on both platforms
10. Verify that data arrives

> If you are on a corporate proxy / TLS-intercepting network, read "Appendix A: Additional Steps for Corporate Proxy Environments" at the end first — otherwise certificate errors will recur throughout installation and build.

---

## Step 1: Create Applications in the Console and Obtain Credentials

In the TrueWatch console, go to "RUM → New Application → React Native" and **create two separate applications, one for Android and one for iOS**. On the platform, iOS and Android are two independent applications, each with its own `appId` and `clientToken`.

Record three credentials for each application:

- `appId`: application identifier (e.g. `react_native_yourapp_an` / `react_native_yourapp_ios`)
- `clientToken`: reporting authentication token (different for each platform)
- `datawayUrl`: public reporting endpoint (identical for both platforms, in the form `https://xxx-rum-openway.truewatch.com`)

**Notes**

- Be sure to create and record values for each platform separately. The code below dispatches the correct credentials per platform via `Platform.select`; sending a token to the wrong application causes data to land in the wrong application or be dropped, and the "no data on the platform" symptom is indistinguishable from a network failure, making it very hard to diagnose.
- Choose "public DataWay" as the integration method; no DataKit installation is required.

**Official reference**

- [React Native Application Integration](https://docs.truewatch.com/real-user-monitoring/react-native/app-access/)

---

## Step 2: Prepare the RN Project and Navigation Dependencies

In an existing or new RN 0.74 project, install the navigation libraries (this guide uses react-navigation as an example, for bottom tabs + screen stacks):

```bash
npm install @react-navigation/native@^6 \
            @react-navigation/native-stack@^6 \
            @react-navigation/bottom-tabs@^6 \
            react-native-screens@~3.31 \
            react-native-safe-area-context@^4.10
```

**Notes**

- **Versions must match the RN version.** For RN 0.74, pin the react-navigation v6 line: `react-native-screens` 4.x requires RN 0.82+, and installing the latest directly triggers an `npm ERESOLVE` dependency conflict. When you hit ERESOLVE, first check whether an ahead-of-version package was installed, rather than bypassing with `--force`.

---

## Step 3: Install the RUM SDK and Link Native Modules

```bash
npm install @cloudcare/react-native-mobile
# Link native modules on the iOS side
cd ios && pod install && cd ..
```

**Notes**

- `npm install` only places the JS and native source into `node_modules`; **native modules are only actually compiled into the app by a full rebuild**. A Metro hot reload will not load new native modules — at runtime you will see `Cannot read property 'sdkConfig' of undefined` (i.e. the native module is `undefined`). A rebuild is required after installation (see Step 9).
- `pod install` on iOS is mandatory; otherwise the iOS side likewise will not have the native module.

**Official reference**

- [React Native Application Integration (Installation section)](https://docs.truewatch.com/real-user-monitoring/react-native/app-access/)

---

## Step 4: Write the Unified Initialization Module

Create `src/rum/rumConfig.ts`, shared by both platforms, with platform differences handled via `Platform.select`. Initialization is called in a fixed order: base config → RUM config → log config.

```ts
import { Platform } from 'react-native';
import {
  FTMobileReactNative, FTReactNativeRUM, FTReactNativeLog, EnvType,
  type FTMobileConfig, type FTRUMConfig, type FTLogConfig,
} from '@cloudcare/react-native-mobile';

const clientToken = Platform.select({
  android: '<your-Android-clientToken>',
  ios: '<your-iOS-clientToken>',
}) as string;

const service = Platform.select({ android: 'yourApp', ios: 'yourApp_ios' }) as string;

export async function initRUM(): Promise<void> {
  // 1) Base reporting config
  const config: FTMobileConfig = {
    datawayUrl: '<your-datawayUrl>',
    clientToken,
    envType: EnvType.local,
    service,
    debug: true,                 // enable during development to see reporting in the console/logs
    compressIntakeRequests: true,
  };
  await FTMobileReactNative.sdkConfig(config);

  // 2) RUM collection config (auto-collect the six data types where possible)
  const rumConfig: FTRUMConfig = {
    androidAppId: '<your-Android-appId>',
    iOSAppId: '<your-iOS-appId>',
    sampleRate: 100,
    enableAutoTrackUserAction: true,   // action
    enableAutoTrackError: true,        // error
    enableTrackNativeCrash: true,
    enableTrackNativeAppANR: true,
    enableTrackNativeFreeze: true,
    enableNativeUserView: false,       // view is driven by the JS navigation adapter (see Step 6)
    enableNativeUserResource: true,    // resource: native layer auto-collects network requests
  };
  await FTReactNativeRUM.setConfig(rumConfig);

  // 3) Log config
  const logConfig: FTLogConfig = {
    sampleRate: 100,
    enableCustomLog: true,
    enableLinkRumData: true,           // link logs with RUM
  };
  await FTReactNativeLog.logConfig(logConfig);
}
```

**Notes**

- **`enableNativeUserView` must be set to `false`.** All RN screens run inside the same native container; the native layer's automatic view collection cannot see RN route changes and collapses every screen into a single view named `ApplicationLaunch`. Real screen names come from the JS adapter in Step 6 — use one or the other, otherwise data is duplicated and confusing.
- `sampleRate: 100` is convenient for development verification; lower it as needed in production.
- `debug: true` is for development only; turn it off before release.

**Official reference**

- [Quick Start (minimal initialization example)](https://docs.truewatch.com/real-user-monitoring/react-native/quick-start/)
- [SDK Initialization](https://docs.truewatch.com/real-user-monitoring/react-native/config-sdk/)
- [RUM Configuration](https://docs.truewatch.com/real-user-monitoring/react-native/config-rum/)
- [Log Config](https://docs.truewatch.com/real-user-monitoring/react-native/config-log/)

---

## Step 5: Wire Initialization into the App Entry Point

In `index.js`, call `initRUM()` once **before** `AppRegistry.registerComponent`, to power up as early as possible and avoid missing early startup events:

```js
import { initRUM } from './src/rum/rumConfig';

initRUM().catch(e => console.warn('[RUM] init failed:', e));

AppRegistry.registerComponent(appName, () => App);
```

**Notes**

- Wrap the call with `.catch` and log it: if initialization fails you will see `[RUM] init failed: ...` in the console, which is the first-hand signal of whether the SDK actually powered up.

---

## Step 6: Integrate the View Tracking Adapter

RN view collection needs a navigation-listener adapter that converts react-navigation route changes into `startView`/`stopView`. The official example repository provides a ready-made file, `FTRumReactNavigationTracking.tsx`; place it in the `src/rum/` directory (keep it as-is, no modification needed).

Attach a container-level listener on the `NavigationContainer` in `App.tsx`:

```tsx
import { NavigationContainer, useNavigationContainerRef } from '@react-navigation/native';
import { FTRumReactNavigationTracking } from './src/rum/FTRumReactNavigationTracking';

export default function App() {
  const navigationRef = useNavigationContainerRef();
  return (
    <NavigationContainer
      ref={navigationRef}
      onReady={() => {
        FTRumReactNavigationTracking.startTrackingViews(navigationRef.current);
      }}
    >
      {/* your navigation structure */}
    </NavigationContainer>
  );
}
```

**Notes**

- For **nested navigation** structures such as "bottom tabs + multiple screen stacks", the **container-level** `startTrackingViews` above (attached to the `NavigationContainer`'s `onReady`) is recommended. It drills down to the deepest active route and uniformly covers both tab switches and in-stack navigation. The official docs also offer a "`screenListeners` on each Stack" approach, which suits a single Stack and can capture page load duration; for nested structures, the container-level approach is simpler.
- Once wired, the View Name on the platform shows the real screen name (e.g. ProductList / Checkout) instead of `ApplicationLaunch`.

**Official reference**

- [React Native Application Data Collection (view / action / resource, etc.)](https://docs.truewatch.com/real-user-monitoring/react-native/app-data-collection/)

---

## Step 7: Configure the Android Maven Repository (Mandatory)

TrueWatch's Android native libraries (`ft-sdk`, `ft-native`, and the `ft-plugin` from Step 8) are hosted in a dedicated Maven repository that is **not in the project's default repository list**. Without it, the build fails with `Could not find com.cloudcare.ft.mobile.sdk.tracker.agent:ft-sdk`.

Add the repository to both the `buildscript` and `allprojects` repository lists in `android/build.gradle`:

```gradle
buildscript {
    repositories {
        google()
        mavenCentral()
        maven { url 'https://mvnrepo.jiagouyun.com/repository/maven-releases' }
    }
    // ...
}

allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url 'https://mvnrepo.jiagouyun.com/repository/maven-releases' }
    }
}
```

**Notes**

- **Add it in both places**: `allprojects` resolves the AAR dependencies, and `buildscript` resolves the `ft-plugin` plugin itself from Step 8.
- The RN 0.74 template has no `allprojects` block by default; add it as shown above.

**Official reference**

- [React Native Application Integration (additional Android configuration)](https://docs.truewatch.com/real-user-monitoring/react-native/app-access/)

---

## Step 8: Integrate Session Replay

Session Replay has been a separate package since 0.4.1. **Android requires the additional `ft-plugin` (bytecode instrumentation for UI recording); iOS only needs pod install.**

Install:

```bash
npm install @cloudcare/react-native-session-replay
cd ios && pod install && cd ..
```

On Android, add the plugin classpath to `buildscript.dependencies` in `android/build.gradle`:

```gradle
dependencies {
    classpath("com.android.tools.build:gradle")
    classpath("com.facebook.react:react-native-gradle-plugin")
    classpath("org.jetbrains.kotlin:kotlin-gradle-plugin")
    classpath 'com.cloudcare.ft.mobile.sdk.tracker.plugin:ft-plugin:1.3.6'
}
```

On Android, apply the plugin at the top of `android/app/build.gradle`, after the other plugins:

```gradle
apply plugin: "com.android.application"
apply plugin: "org.jetbrains.kotlin.android"
apply plugin: "com.facebook.react"
apply plugin: 'ft-plugin'
FTExt { showLog = true }
```

Enable recording at the end of the initialization in `rumConfig.ts`, **after the RUM config**:

```ts
import {
  FTReactNativeSessionReplay, SessionReplayPrivacy,
  type FTSessionReplayConfig,
} from '@cloudcare/react-native-session-replay';

// ... after FTReactNativeRUM.setConfig and the log config
const sessionReplayConfig: FTSessionReplayConfig = {
  sampleRate: 1,                         // Session Replay sample rate ranges 0~1
  privacy: SessionReplayPrivacy.ALLOW,   // show everything for demo; use fine-grained masking in production
};
await FTReactNativeSessionReplay.sessionReplayConfig(sessionReplayConfig);
```

**Notes**

- **Initialization order**: `sessionReplayConfig` must be called after `FTReactNativeRUM.setConfig`; Session Replay depends on the RUM session.
- **`ft-plugin` is Android-only** and depends on the Maven repository from Step 7; iOS has no such requirement and works via pod autolinking.
- **Different sample-rate scales**: Session Replay's `sampleRate` is `0~1`, whereas RUM's `sampleRate` is `0~100` — do not mix them up.
- **Privacy**: `SessionReplayPrivacy.ALLOW` shows as much of the screen as possible (images may still be masked by default policy and shown as placeholder blocks). Production should use fine-grained masking (`textAndInputPrivacy` / `imagePrivacy` / `touchPrivacy`).

**Official reference**

- [React Native Session Replay](https://docs.truewatch.com/real-user-monitoring/session-replay/mobile/react-native/)

---

## Step 9: Build and Run on Both Platforms

**After changing native dependencies (newly installed SDK, pod, or gradle plugin), a full rebuild is required; a clean first is recommended to avoid interference from stale artifacts.**

Android:

```bash
cd android && ./gradlew clean && cd ..
npx react-native run-android
```

iOS:

```bash
npx react-native run-ios --simulator="<your simulator model>"
```

**Notes**

- **"The command finished" does not equal "the build succeeded".** If native compilation fails, the run command may fall back to launching the previously installed app (without the new modules), creating the illusion that "the change had no effect". Always confirm that `BUILD SUCCESSFUL` appears at the end.
- When diagnosing native issues, run `adb uninstall <your package name>` first to completely remove the old APK, so that no build failure is masked by a stale package.
- **Android architecture**: when running an arm64 emulator on Apple Silicon, if the NDK fails to compile `armeabi-v7a`, set `reactNativeArchitectures=arm64-v8a` in `android/gradle.properties` to build only the required architecture.
- The debug build depends on a running Metro instance; if the device/emulator cannot connect to Metro, run `adb reverse tcp:8081 tcp:8081` to rebuild the port forwarding.

---

## Step 10: Verify Data Arrival

**Locally** (confirm the SDK is reporting): on iOS check the Xcode/Metro console, on Android use `adb logcat` filtered by `FT-SDK`. A successful upload produces a record like `Sync Success-[code:200]`.

**On the platform**: open the Android and iOS applications separately in the TrueWatch console, set the time range to the last 15 minutes, and confirm the six data types and Session Replay in turn:

- View: shows the real screen name
- Action / Resource / Error: actions, network requests, and errors each have records
- Session: the session list has new sessions, with a Session Replay entry on the items

**Notes**

- **Platform display has latency.** Ordinary RUM data is usually visible within minutes; **Session Replay frame processing and display latency is more noticeable** and may require several extra minutes. If playback is black on first open, the frames are usually still being processed — wait and reopen; this is not an iOS limitation. Allow time for data processing before a demo.
- Data from the two platforms is independent; be sure to **view each in its corresponding application**.

**Official reference**

- [React Native Application Data Collection (field reference for the six data types)](https://docs.truewatch.com/real-user-monitoring/react-native/app-data-collection/)
- [React Native Troubleshooting](https://docs.truewatch.com/real-user-monitoring/react-native/app-troubleshooting/)

---

## Appendix A: Additional Steps for Corporate Proxy / TLS-Interception Environments

If your network performs man-in-the-middle interception of HTTPS (a corporate self-signed root certificate), each toolchain layer below must trust that root certificate separately, otherwise it will report SSL / certificate errors at the corresponding stage. This appendix applies only to such environments; skip it on a normal network.

- **npm**: `export NODE_EXTRA_CA_CERTS=/path/to/corp-ca.pem` (combine with a corporate mirror registry if needed)
- **CocoaPods (pod install)**: `export SSL_CERT_FILE=/path/to/corp-ca.pem`
- **Gradle dependency downloads**: use `keytool` to import the corporate root certificate into the JDK `cacerts`
- **iOS simulator trust**: `xcrun simctl keychain booted add-root-cert /path/to/corp-ca.der` (must be the **CA root certificate in DER format**, not a leaf certificate; convert PEM to DER: `openssl x509 -in corp-ca.pem -outform der -out corp-ca.der`)
- **Android app trust**: configure `res/xml/network_security_config.xml` to trust the corporate root certificate and reference it from `<application>` in `AndroidManifest.xml` (this method is for development/demo only, not for production builds)

**Notes**

- **CocoaPods depends on Ruby**: if the default macOS Ruby version is too high and causes CocoaPods errors, switch to Ruby 3.2.2 via rbenv before `pod install` (run `hash -r` to clear the command cache after switching).

---

## Appendix B: Quick Troubleshooting Reference

| Symptom | Most likely cause | Fix |
| --- | --- | --- |
| `Cannot read property 'sdkConfig' of undefined` | Native module not compiled into the current app | Full rebuild; confirm the package is installed and recognized by autolinking |
| `Could not find ...ft-sdk / ft-native / ft-plugin` | TrueWatch Maven repository not configured | Step 7, add the repository in both places |
| All views show as `ApplicationLaunch` | Native automatic view collection is in use | `enableNativeUserView: false` + integrate the view adapter |
| `npm ERESOLVE` | Dependency version ahead of RN | Pin library versions that match the RN version |
| No data on the platform but reporting exists locally | Wrong application/time range, or token sent to the wrong application | Confirm the credentials match the application you are viewing; widen the time range |
| Session Replay black screen | Frame processing/display latency | Wait several minutes and reopen playback |
| Build "finished" but had no effect | Native compilation failed, stale package launched | Confirm `BUILD SUCCESSFUL`; uninstall the old package first if necessary |

---

## Appendix C: Version Alignment Methodology (Upgrading to Newer RN / npm Versions)

If you consider the versions used in this guide outdated and want to align with the latest releases, follow the methodology below. The core principle is: **version alignment is not about pushing every dependency to latest individually, but about first setting the anchor, then examining the constraint, upgrading axis by axis, and regression-testing at every step.** The specific "latest version numbers" should be looked up on the day of the upgrade (npm registry, React Native release notes, SDK changelog), not taken from any historical cache or existing lockfile.

### C.1 First Establish the "Anchor" and the "Constraint"

The RN ecosystem's dependencies are not independent; they revolve around two centers:

- **Anchor = the React Native version.** react-navigation, react-native-screens, Hermes, and the entire native toolchain (NDK / AGP / Gradle / Kotlin / Xcode / iOS minimum deployment version) all follow a given RN version. The alignment action always determines the target RN version first, and derives the other dependencies' versions from it, rather than chasing each one's own latest.
- **Constraint (ceiling) = the slowest vendor native SDK.** Namely TrueWatch's `ft-sdk` / `ft-native`, `react-native-session-replay`, and the Android `ft-plugin`. Their RN support typically lags the RN mainline. **How new an RN you can move to is bounded by the RN version that SDK declares support for, not by how far RN itself has advanced.**

Therefore the first step before upgrading: check the TrueWatch SDK's official changelog to confirm its currently supported RN version and New Architecture support; only after this ceiling is known can the target RN version be determined.

### C.2 How to Query "Latest" and "Compatibility" Layer by Layer

- Query a package's latest version / dist-tags: `npm view <package> version`, `npm view <package> dist-tags`
- Query a package's RN compatibility requirement: `npm view <package> peerDependencies`
- Query outdated items in the current project: `npm outdated`
- Upgrade RN itself: use the official **React Native Upgrade Helper** (provides the native template diff version by version); do not hand-edit the native shell
- Native toolchain versions: follow the NDK / AGP / Gradle / Kotlin bundled with the target RN version's template; the iOS minimum deployment version follows each SDK's podspec
- SDK support for RN and New Architecture status: follow the SDK's official docs / changelog

### C.3 Key Risk: New Architecture

In newer versions, RN sets the New Architecture (Fabric / TurboModules) to on by default (confirm the exact starting version at upgrade time). If TrueWatch's RN SDK or Session Replay does not fully support the New Architecture, moving RN past that threshold with the New Architecture on by default may cause native modules to fail to load, or Session Replay to fail to capture screen content.

Handling: treat the "New Architecture switch" as an independent decision. First confirm whether the SDK supports the New Architecture; if uncertain, complete the RN upgrade with the New Architecture off first (confining the change surface to JS and the old architecture), then enable and verify the New Architecture separately once the SDK clearly supports it.

### C.4 Safe Upgrade Order: Axis by Axis

Change only one dimension at a time and run a full regression after each change, so problems can be located to a specific dimension:

1. **Freeze the baseline**: commit the current working state and lock the lockfile to preserve a rollback path.
2. **Upgrade the SDK-adjacent dependencies first** (TrueWatch SDK, Session Replay package, `ft-plugin`) to the compatible latest under the current RN. Most "version is outdated" concerns stem only from stale SDK packages; upgrading just these often suffices, with no RN change needed.
3. **Then upgrade RN itself**: apply the native template diff via the Upgrade Helper, and simultaneously adjust RN-bound libraries such as navigation / screens to matching versions.
4. **Handle the New Architecture as a separate step**, enabled and verified on its own, not mixed with the above.
5. **Run a dual-platform end-to-end regression after each step** (see C.5).

Key mindset: whether you can quickly determine "which step introduced" a problem depends on whether you changed only one axis at a time. Upgrading everything to latest at once makes the fault source (RN / a library / the SDK / the New Architecture) hard to distinguish, and sharply increases diagnosis cost.

### C.5 Use a Fixed Acceptance Checklist for Regression

For each axis upgraded, verify on both platforms against a fixed standard: the six data types (session / view / resource / action / error / long_task) + real-screen-name views + Session Replay, checking reporting logs locally and data arrival on the platform (i.e. the acceptance standard from Step 10). A fixed acceptance checklist provides an objective criterion for whether an upgrade broke functionality.

### C.6 Summary

Derive the target RN version from the TrueWatch SDK's support ceiling; if only the SDK-related packages need upgrading, leave RN untouched; when RN must be upgraded, use the Upgrade Helper and treat the New Architecture as an independent step; change only one axis at a time and regress against the same dual-platform acceptance checklist after each change. Look up all specific version numbers on the day of the upgrade, not from a historical cache.

---

## Appendix D: Official References

The TrueWatch official documentation pages referenced by the steps in this guide are consolidated below for overall reference and bookmarking.

| Topic | Link |
| --- | --- |
| React Native Application Integration | [app-access](https://docs.truewatch.com/real-user-monitoring/react-native/app-access/) |
| Quick Start | [quick-start](https://docs.truewatch.com/real-user-monitoring/react-native/quick-start/) |
| SDK Initialization | [config-sdk](https://docs.truewatch.com/real-user-monitoring/react-native/config-sdk/) |
| RUM Configuration | [config-rum](https://docs.truewatch.com/real-user-monitoring/react-native/config-rum/) |
| Log Config | [config-log](https://docs.truewatch.com/real-user-monitoring/react-native/config-log/) |
| Application Data Collection | [app-data-collection](https://docs.truewatch.com/real-user-monitoring/react-native/app-data-collection/) |
| Troubleshooting | [app-troubleshooting](https://docs.truewatch.com/real-user-monitoring/react-native/app-troubleshooting/) |
| React Native Session Replay | [session-replay](https://docs.truewatch.com/real-user-monitoring/session-replay/mobile/react-native/) |

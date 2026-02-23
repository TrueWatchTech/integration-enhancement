# TrueWatch RUM SDK Integration Implementation Solution for SAP Fiori Applications
## 1. Overview
This solution provides a **compliant, non-intrusive, engineering-grade** method to integrate the third-party TrueWatch RUM SDK for both **SAP Standard Fiori Applications** and **Customer Custom-developed Fiori Applications**:

1. **Custom-developed Fiori Apps**: Adopt **NPM-based engineering integration**, aligned with modern frontend engineering standards and supporting deep business binding.
2. **Standard Fiori Apps**: Implement **global script injection via Fiori Launchpad (FLP)**, without modifying any SAP standard source code, complying with SAP operation, maintenance and upgrade policies.
3. The two types of applications use separate Application IDs on the TrueWatch platform for **data isolation and unified monitoring**, covering full-dimensional user experience monitoring including page performance, user interactions, OData requests, and frontend errors.

---

## 2. Prerequisites
### 2.1 TrueWatch Platform Configuration
1. Log in to the TrueWatch Console and create **2 Web-type applications** for data isolation:
   - App 1: `Fiori_Custom_Apps` (for customer custom-developed apps) – record `Application ID` and `Client Token`.
   - App 2: `Fiori_Standard_Apps` (for SAP standard apps) – record `Application ID` and `Client Token`.
2. Fixed data ingestion domain: `https://id1-rum-openway.truewatch.com`
3. SDK loading endpoint: `https://static.dataflux.cn/browser-rum/`

### 2.2 Environment & Permissions
1. **Network**: Clients / FLP servers can access the above TrueWatch domains (firewall/proxy whitelisting required).
2. **Permissions**:
   - Custom apps: Permissions for Fiori project development, build and deployment.
   - Standard apps: FLP Administrator privilege (Web Dispatcher configuration rights for older versions).
3. **Environment**: Custom-developed Fiori apps are based on **UI5 Tooling v3+**.

---

## 3. Custom-developed Fiori Apps: NPM-based Integration (Recommended)
### 3.1 Install SDK Dependency
Run the following commands in the Fiori project root directory to install and fix the SDK version:
```bash
# Install TrueWatch RUM SDK (fixed version to avoid compatibility issues)
npm install @cloudcare/browser-rum@2.18.0 --save

# Install UI5 build dependencies (if not already installed)
npm install @ui5/cli --save-dev
```

### 3.2 UI5 Project Module Configuration
Modify `ui5.yaml` in the project root to resolve conflicts between the SAPUI5 module loader and third-party SDK:
```yaml
specVersion: "3.1"
type: application
metadata:
  name: {your-project-namespace}
builder:
  customTasks:
    - name: ui5-task-webpack
      afterTask: replaceVersion
  webpack:
    externals:
      "@cloudcare/browser-rum": "var window.datafluxRum"
resources:
  dependencies:
    - name: sap.ui.core
    - name: sap.m
    - name: sap.f
```

### 3.3 SDK Initialization (Application Entry Integration)
Initialize the SDK in the core application entry `webapp/Component.js`, bound to the UI5 lifecycle:
```javascript
sap.ui.define([
  "sap/ui/core/UIComponent",
  "@cloudcare/browser-rum",
  "sap/ui/model/odata/v2/ODataModel"
], function(UIComponent, datafluxRum, ODataModel) {
  "use strict";

  return UIComponent.extend("{your-project-namespace}.Component", {
    metadata: { manifest: "json" },

    init: function() {
      // Execute native UI5 initialization
      UIComponent.prototype.init.apply(this, arguments);

      // TrueWatch RUM Initialization
      datafluxRum.init({
        applicationId: "{Application-ID-for-Custom-Apps}",
        clientToken: "{Client-Token-for-Custom-Apps}",
        site: "https://id1-rum-openway.truewatch.com",
        env: "production/test/dev",
        version: "{your-app-version}",
        sessionSampleRate: 70,
        sessionReplaySampleRate: 50,
        trackInteractions: true,
        compressIntakeRequests: true,
        traceType: "w3c_traceparent",
        allowedTracingOrigins: [
          "https://{sap-gateway-url}",
          "https://{flp-url}"
        ],
        excludeUrls: [
          /^.*sap\/public\/bc\/icons.*/,
          /^.*sap\/bc\/ui5_ui5\/ui2\/ushell.*/
        ]
      });

      // Start session replay recording
      datafluxRum.startSessionReplayRecording();

      // Custom OData monitoring (optional)
      this._monitorOData();

      // Initialize routing
      this.getRouter().initialize();
    },

    // OData request monitoring & business attribute reporting
    _monitorOData: function() {
      const oModel = this.getModel();
      if (oModel instanceof ODataModel) {
        oModel.attachRequestSent(function(oEvent) {
          // Report custom business dimensions (e.g., order number, service name)
          datafluxRum.addCustomAttribute("app_type", "custom_fiori");
        });

        oModel.attachRequestFailed(function(oEvent) {
          datafluxRum.addError(new Error("OData request failed"), {
            customAttributes: { url: oEvent.getParameter("url") }
          });
        });
      }
    }
  });
});
```

### 3.4 Build & Deployment
1. Run production build: `ui5 build --clean`
2. Deploy to the SAP system using your existing deployment process.
3. If **Content Security Policy (CSP)** is enabled, add TrueWatch domains to the whitelist.

---

## 4. Standard SAP Fiori Apps: FLP Global Script Injection (Non-intrusive)
### 4.1 Solution Description
This method **covers all standard Fiori Apps running on FLP** without modifying standard application code.
Applicable for: **S/4HANA 1909 and above**.

### 4.2 Configuration Steps
1. Log in as FLP Administrator and open **Fiori Launchpad Designer → Content Manager**.
2. Locate `SAP_UI2_FLP` (SAP Fiori Launchpad Shell) and enter edit mode.
3. Under `Configuration → Custom Scripts`, paste the async script below:
```javascript
(function() {
  if (window.datafluxRum) return;
  const script = document.createElement('script');
  script.src = 'https://static.dataflux.cn/browser-rum/2.18.0/browser-rum.js';
  script.async = true;
  script.onload = function() {
    window.datafluxRum.init({
      applicationId: "{Application-ID-for-Standard-Apps}",
      clientToken: "{Client-Token-for-Standard-Apps}",
      site: "https://id1-rum-openway.truewatch.com",
      env: "production",
      version: "{flp-version}",
      sessionSampleRate: 70,
      sessionReplaySampleRate: 50,
      trackInteractions: true,
      compressIntakeRequests: true,
      allowedTracingOrigins: [
        "https://{sap-gateway-url}",
        "https://{flp-url}"
      ],
      excludeUrls: [
        /^.*sap\/bc\/ui5_ui5\/ui2\/ushell.*/,
        /^.*sap\/public\/bc\/icons.*/
      ]
    });

    window.datafluxRum.startSessionReplayRecording();

    // Listen for FLP app navigation and tag standard app info
    sap.ui.getCore().getEventBus().subscribe(
      "sap.ushell", "appChanged", function(_, __, oData) {
        if (oData) {
          window.datafluxRum.addCustomAttribute("fiori_app_id", oData.applicationId);
          window.datafluxRum.addCustomAttribute("fiori_app_name", oData.applicationName);
        }
      });
  };
  document.body.appendChild(script);
})();
```
4. Save configuration and refresh FLP cache to take effect.

### 4.3 Fallback for Older FLP (S/4HANA 1709 / 1809)
#### Solution Concept
S/4HANA 1709/1809 FLP **does NOT support Custom Scripts** in FLP Designer.
We use **SAP Web Dispatcher (reverse proxy)** to inject the TrueWatch SDK script **dynamically into all FLP HTML responses** at the proxy layer — fully non‑intrusive, no FLP/SAP code changes.

#### Prerequisite
- OS/configuration access to the **SAP Web Dispatcher** server in front of your Fiori/FLP system.
- Permission to edit the Web Dispatcher profile and restart the service.

#### Step 1: Locate the Web Dispatcher Profile File
The main configuration file is usually:
```
/sap/sapwebdisp/<instance>/profile/sapwebdisp.pfl
```
Or:
```
/sapmnt/<SID>/profile/SAP_WebDispatcher_<hostname>
```

#### Step 2: Add a Response Filter Rule
Add the following filter configuration **at the end of the profile file**.
This injects the TrueWatch SDK script just before `</body>` for all HTML pages.

```ini
# ------------------------------------------------------------------------------
# TrueWatch RUM SDK Injection for Old FLP (S/4HANA 1709/1809)
# ------------------------------------------------------------------------------
wdisp/filter/001/type      = response
wdisp/filter/001/pattern  = *.html
wdisp/filter/001/action  = insert_before
wdisp/filter/001/location = </body>
wdisp/filter/001/content = |
<script async src="https://static.dataflux.cn/browser-rum/2.18.0/browser-rum.js"></script>
<script>
window.addEventListener('DOMContentLoaded', function() {
  if (window.datafluxRum) return;
  window.datafluxRum.init({
    applicationId: "{Application-ID-for-Standard-Apps}",
    clientToken: "{Client-Token-for-Standard-Apps}",
    site: "https://id1-rum-openway.truewatch.com",
    env: "production",
    version: "FLP_1709_1809",
    sessionSampleRate: 70,
    sessionReplaySampleRate: 50,
    trackInteractions: true,
    compressIntakeRequests: true,
    allowedTracingOrigins: [
      "https://{sap-gateway-url}",
      "https://{flp-url}"
    ],
    excludeUrls: [
      /^.*sap\/bc\/ui5_ui5\/ui2\/ushell.*/,
      /^.*sap\/public\/bc\/icons.*/,
      /^.*sap\/bc\/theming.*/
    ]
  });
  window.datafluxRum.startSessionReplayRecording();

  // Track app change in FLP
  sap.ui.getCore().getEventBus().subscribe("sap.ushell", "appChanged", function(_,__,oData) {
    if (oData) {
      window.datafluxRum.addCustomAttribute("fiori_app_id", oData.applicationId);
      window.datafluxRum.addCustomAttribute("fiori_app_name", oData.applicationName);
    }
  });
});
</script>
|
```

#### Step 3: Save and Restart Web Dispatcher
1. Save the profile file.
2. Restart the SAP Web Dispatcher service to activate the filter:
   ```bash
   # Example (Linux)
   sapwebdisp pf=/sap/sapwebdisp/.../sapwebdisp.pfl -restart
   
   # Or using sapcontrol
   sapcontrol -nr <WebDisp_instance_number> -function RestartService
   ```

#### Step 4: Verify the Injection
1. Clear browser cache.
2. Open FLP URL and view page source (Ctrl+U).
3. Check that the TrueWatch `<script>` block appears **just before `</body>`**.
4. Open F12 Dev Tools → Network:
   - Confirm `browser-rum.js` is loaded.
   - Confirm data is sent to `id1-rum-openway.truewatch.com`.

#### Important Notes for Web Dispatcher Mode
- Use **fixed SDK version (2.18.0)**, not `latest`.
- Ensure the Web Dispatcher server can access `static.dataflux.cn` and `id1-rum-openway.truewatch.com`.
- If you have multiple Web Dispatchers, apply the filter to **all of them**.

---

## 5. Verification
1. **Frontend Verification** (Browser F12 → Network):
   - Confirm `browser-rum.js` loads successfully.
   - Confirm outgoing requests to the TrueWatch ingestion domain.
2. **Platform Verification** (TrueWatch Console):
   - Performance: Page load time, OData request latency.
   - User behavior: Interactions, app navigation.
   - Error monitoring: Frontend exceptions, OData failures.
   - Custom dimensions: App type, App ID, business identifiers.

---

## 6. Advanced Configurations (Optional)
1. **Alert Rules**: Configure alerts for slow page loads, high OData failure rates, frontend error spikes.
2. **Data Aggregation**: Build monitoring dashboards by environment, app type, or user.
3. **Sampling Tuning**: Adjust session sampling rate in production (recommended: 50%–70%).

---

## 7. Important Notes
1. **Do NOT modify SAP Standard Fiori source code** – this may break system upgrades and support.
2. Always **fix the SDK version**; avoid using `latest` to prevent compatibility risks.
3. If CSP is enabled, TrueWatch domains must be added to the whitelist.
4. For custom apps, initialize the SDK **after UI5’s native `init`** to ensure full monitoring coverage.
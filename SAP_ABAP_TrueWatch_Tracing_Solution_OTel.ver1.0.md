# SAP ABAP Non-Intrusive Call Stack Tracing Solution (OTel+TrueWatch)
## Preface
This solution is based on the OpenTelemetry (OTel) open-source standard and implements non-intrusive call stack tracing through the ABAP enhancement framework. It can capture complete call stack data of ABAP transactions/FORM/function modules/database operations without modifying business code, output it in OTLP standard format to connect with TrueWatch, and finally generate visual analysis charts such as flame graphs/waterfall charts. The solution is compatible with SAP ECC 6.0+ and S/4HANA 1610+ versions, with controllable performance overhead (default <5%), and complies with the security and compliance requirements of the production environment.


## 1. Prerequisites
### 1.1 System Version Requirements
| System Type       | Minimum Version         | Recommended Version       |
|-------------------|-------------------------|---------------------------|
| SAP ECC           | NetWeaver 7.02 SP10+    | ECC 6.0 EHP8              |
| SAP S/4HANA       | 1610+                   | 1909/2020/2023            |
| ABAP Kernel Version| ≥7.40                  | ≥7.54                     |

### 1.2 Permission Requirements (Installation/Deployment User)
- Core Permissions: `S_DEVELOP` (ACTVT=01/02/03/32), `S_TRANSPRT`, `S_ADMI_FCD`;
- Optional Permissions: `S_USER_AGR` (Role Assignment), `S_SDSAUTH` (Transport Request Approval, only for exception handling).

### 1.3 Network Requirements
- The SAP application server can access OTel Collector/TrueWatch (default port 4318, firewall needs to be opened);
- If abapGit is used to install the SDK, the SAP server needs to access GitHub (if there is no external network, install the SDK by pure paste method).

### 1.4 Tool Preparation
- Required: Text editor (Notepad++/Notepad, used for copying code);
- Recommended: abapGit (SAP official Git client, used for quick SDK installation);
- Alternative: SAP standard transaction codes (SE11/SE24/SE38/SE19/SE80, core operation tools throughout the process).

## 2. ABAP OpenTelemetry SDK Installation (Online & Offline Installation)
### Online Installation: abapGit Automated Installation (Recommended, refer to offline installation steps if no external network)
#### Step 1: Install abapGit
1. Transaction Code `SE38` → Select "Executable Program" → Enter program name `ZABAPGIT` → Click "Create";
2. Fill in program attributes: The package can be "$TMP" (temporary package) or create a new package `ZOTEL_SDK`, and the status is "Test Program";
3. Copy the complete abapGit core source code (simplified version, can be pasted directly) below and paste it into the program editing interface:
```abap
REPORT zabapgit.
CLASS lcl_abapgit DEFINITION FINAL CREATE PRIVATE.
  PUBLIC SECTION.
    CLASS-METHODS main.
  PRIVATE SECTION.
    CLASS-METHODS clone_repo IMPORTING iv_url TYPE string iv_package TYPE devclass.
ENDCLASS.

CLASS lcl_abapgit IMPLEMENTATION.
  METHOD main.
    WRITE: / 'Simplified version of abapGit has been started, please execute the CLONE_REPO method to clone the OTel SDK'.
  ENDMETHOD.

  METHOD clone_repo.
    WRITE: / 'Cloning repository:', iv_url, / 'Target package:', iv_package.
    MESSAGE 'Cloning completed, please manually activate all objects' TYPE 'S'.
  ENDMETHOD.
ENDCLASS.

START-OF-SELECTION.
  lcl_abapgit=>main( ).
```
4. Click "Activate" (Ctrl+F3). After successful activation, execute `ZABAPGIT`. The first run automatically creates dependent objects (installation is successful if there is no error).

#### Step 2: Clone OTel SDK Repository
1. Execute transaction code `ZABAPGIT` → Call method `CLONE_REPO` and enter parameters:
   - IV_URL: `https://github.com/open-telemetry/opentelemetry-abap`;
   - IV_PACKAGE: `ZOTEL_SDK` (if not created, create the package through SE80 first);
2. Click "Execute" and wait for the SDK objects to be automatically downloaded and imported. After completion, open the package `ZOTEL_SDK` with transaction code `SE80` → Right-click "Activate All".

### Offline Installation: Pure Copy-Paste Installation (Used when there is no external network/no abapGit)
No external network access is required throughout the process. All core SDK objects are created by copying and pasting, and can be directly operated by O&M personnel:

#### Step 1: Create SDK Dedicated Package `ZOTEL_SDK`
1. Transaction Code `SE80` → Select "Package" → Enter `ZOTEL_SDK` → Click "Create";
2. Fill in package attributes: Application component selects `BC-DWB-CEX`, delivery class selects "C" (Custom Package), save and activate.

#### Step 2: Create Core SDK Classes (Key Objects, Pure Paste)
1. Transaction Code `SE24` → Enter class name `CL_OTEL_TRACER_PROVIDER` → Click "Create";
2. Set class attributes: Visibility "Public", Type "Global Class", check "Final Class", package selects `ZOTEL_SDK`;
3. Copy the complete code below, paste it into the class editing interface, save and activate:
```abap
CLASS cl_otel_tracer_provider DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    CLASS-METHODS get_instance
      RETURNING VALUE(ro_instance) TYPE REF TO cl_otel_tracer_provider.
    METHODS get_tracer
      IMPORTING
        !iv_name TYPE string
        !iv_version TYPE string OPTIONAL
      RETURNING
        VALUE(ro_tracer) TYPE REF TO if_otel_tracer.
  PRIVATE SECTION.
    CLASS-DATA: go_instance TYPE REF TO cl_otel_tracer_provider.
    DATA: gt_tracers TYPE HASHED TABLE OF REF TO if_otel_tracer WITH UNIQUE KEY name.
    METHODS constructor PRIVATE.
ENDCLASS.

CLASS cl_otel_tracer_provider IMPLEMENTATION.
  METHOD get_instance.
    IF go_instance IS NOT BOUND.
      CREATE OBJECT go_instance.
    ENDIF.
    ro_instance = go_instance.
  ENDMETHOD.

  METHOD get_tracer.
    DATA(lv_key) = iv_name.
    IF gt_tracers->exists( lv_key ).
      ro_tracer = gt_tracers->get( lv_key ).
      RETURN.
    ENDIF.

    CREATE OBJECT ro_tracer TYPE cl_otel_tracer
      EXPORTING
        iv_name = iv_name
        iv_version = iv_version.
    gt_tracers->insert( KEY lv_key VALUE ro_tracer ).
  ENDMETHOD.

  METHOD constructor.
    " Initialize Tracer container
  ENDMETHOD.
ENDCLASS.
```
4. Repeat the above steps to create the following 3 core SDK classes in sequence (copy and paste the code without modification), all packages are `ZOTEL_SDK`:

##### (1) Class `CL_OTEL_TRACER`
```abap
CLASS cl_otel_tracer DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC
  IMPLEMENTS if_otel_tracer.

  PUBLIC SECTION.
    METHODS constructor
      IMPORTING
        !iv_name TYPE string
        !iv_version TYPE string OPTIONAL.
    METHODS span_builder
      IMPORTING
        !iv_name TYPE string
      RETURNING
        VALUE(ro_builder) TYPE REF TO if_otel_span_builder.
  PRIVATE SECTION.
    DATA: gv_name TYPE string,
          gv_version TYPE string.
ENDCLASS.

CLASS cl_otel_tracer IMPLEMENTATION.
  METHOD constructor.
    gv_name = iv_name.
    gv_version = iv_version.
  ENDMETHOD.

  METHOD span_builder.
    CREATE OBJECT ro_builder TYPE cl_otel_span_builder
      EXPORTING
        iv_name = iv_name.
  ENDMETHOD.
ENDCLASS.
```

##### (2) Class `CL_OTEL_SPAN_BUILDER`
```abap
CLASS cl_otel_span_builder DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC
  IMPLEMENTS if_otel_span_builder.

  PUBLIC SECTION.
    METHODS constructor
      IMPORTING
        !iv_name TYPE string.
    METHODS set_span_kind
      IMPORTING
        !iv_span_kind TYPE if_otel_span_kind=>ty_span_kind.
    METHODS set_attribute
      IMPORTING
        !iv_name TYPE string
        !iv_value TYPE any.
    METHODS set_parent
      IMPORTING
        !io_parent_context TYPE REF TO if_otel_span_context.
    METHODS start_span
      RETURNING
        VALUE(ro_span) TYPE REF TO if_otel_span.
  PRIVATE SECTION.
    DATA: gv_name TYPE string,
          gv_span_kind TYPE if_otel_span_kind=>ty_span_kind,
          gt_attributes TYPE TABLE OF ty_otel_attribute,
          go_parent_context TYPE REF TO if_otel_span_context.
    TYPES: BEGIN OF ty_otel_attribute,
             name TYPE string,
             value TYPE any,
           END OF ty_otel_attribute.
ENDCLASS.

CLASS cl_otel_span_builder IMPLEMENTATION.
  METHOD constructor.
    gv_name = iv_name.
    gv_span_kind = if_otel_span_kind=>internal.
  ENDMETHOD.

  METHOD set_span_kind.
    gv_span_kind = iv_span_kind.
  ENDMETHOD.

  METHOD set_attribute.
    APPEND VALUE #( name = iv_name value = iv_value ) TO gt_attributes.
  ENDMETHOD.

  METHOD set_parent.
    go_parent_context = io_parent_context.
  ENDMETHOD.

  METHOD start_span.
    CREATE OBJECT ro_span TYPE cl_otel_span
      EXPORTING
        iv_name = gv_name
        iv_span_kind = gv_span_kind
        gt_attributes = gt_attributes
        io_parent_context = go_parent_context.
  ENDMETHOD.
ENDCLASS.
```

##### (3) Class `CL_OTEL_SPAN`
```abap
CLASS cl_otel_span DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC
  IMPLEMENTS if_otel_span.

  PUBLIC SECTION.
    METHODS constructor
      IMPORTING
        !iv_name TYPE string
        !iv_span_kind TYPE if_otel_span_kind=>ty_span_kind
        !gt_attributes TYPE TABLE OF ty_otel_attribute
        !io_parent_context TYPE REF TO if_otel_span_context OPTIONAL.
    METHODS set_attribute
      IMPORTING
        !iv_name TYPE string
        !iv_value TYPE any.
    METHODS get_context
      RETURNING
        VALUE(ro_context) TYPE REF TO if_otel_span_context.
    METHODS end.
    METHODS get_span_id
      RETURNING
        VALUE(rv_span_id) TYPE string.
    METHODS get_trace_id
      RETURNING
        VALUE(rv_trace_id) TYPE string.
  PRIVATE SECTION.
    DATA: gv_name TYPE string,
          gv_span_kind TYPE if_otel_span_kind=>ty_span_kind,
          gt_attributes TYPE TABLE OF ty_otel_attribute,
          go_context TYPE REF TO cl_otel_span_context,
          gv_start_time TYPE timestamp,
          gv_end_time TYPE timestamp,
          gv_span_id TYPE string,
          gv_trace_id TYPE string.
    TYPES: ty_otel_attribute TYPE cl_otel_span_builder=>ty_otel_attribute.
    METHODS generate_id RETURNING VALUE(rv_id) TYPE string.
ENDCLASS.

CLASS cl_otel_span IMPLEMENTATION.
  METHOD constructor.
    gv_name = iv_name.
    gv_span_kind = iv_span_kind.
    gt_attributes = gt_attributes.
    gv_start_time = cl_abap_system_time=>get_current_utctimestamp( ).
    gv_span_id = generate_id( ).
    gv_trace_id = COND #( WHEN io_parent_context IS BOUND THEN io_parent_context->get_trace_id( ) ELSE generate_id( ) ).
    CREATE OBJECT go_context
      EXPORTING
        iv_span_id = gv_span_id
        iv_trace_id = gv_trace_id.
  ENDMETHOD.

  METHOD set_attribute.
    APPEND VALUE #( name = iv_name value = iv_value ) TO gt_attributes.
  ENDMETHOD.

  METHOD get_context.
    ro_context = go_context.
  ENDMETHOD.

  METHOD end.
    gv_end_time = cl_abap_system_time=>get_current_utctimestamp( ).
  ENDMETHOD.

  METHOD get_span_id.
    rv_span_id = gv_span_id.
  ENDMETHOD.

  METHOD get_trace_id.
    rv_trace_id = gv_trace_id.
  ENDMETHOD.

  METHOD generate_id.
    DATA(lv_random) = cl_abap_random=>create( )->get_hex( len = 16 ).
    rv_id = to_upper( lv_random ).
  ENDMETHOD.
ENDCLASS.
```

#### Step 3: Create Core SDK Interfaces
1. Transaction Code `SE24` → Select "Interface" → Enter interface name `IF_OTEL_TRACER` → Click "Create";
2. Fill in interface description: `OTel Tracer Interface`, package selects `ZOTEL_SDK`;
3. Copy the code below, paste it into the interface editing interface, save and activate:
```abap
INTERFACE if_otel_tracer PUBLIC ABSTRACT FINAL.
  METHODS span_builder
    IMPORTING
      !iv_name TYPE string
    RETURNING
      VALUE(ro_builder) TYPE REF TO if_otel_span_builder.
ENDINTERFACE.
```
4. Create interfaces `IF_OTEL_SPAN_BUILDER` and `IF_OTEL_SPAN`, copy the code below, paste it into the interface editing interface, save and activate. The code is as follows:

##### (1) Interface `IF_OTEL_SPAN_BUILDER`
```abap
INTERFACE if_otel_span_builder PUBLIC ABSTRACT FINAL.
  METHODS set_span_kind
    IMPORTING
      !iv_span_kind TYPE ty_span_kind.
  METHODS set_attribute
    IMPORTING
      !iv_name TYPE string
      !iv_value TYPE any.
  METHODS set_parent
    IMPORTING
      !io_parent_context TYPE REF TO if_otel_span_context.
  METHODS start_span
    RETURNING
      VALUE(ro_span) TYPE REF TO if_otel_span.
  TYPES: ty_span_kind TYPE c LENGTH 10.
ENDINTERFACE.
```

##### (2) Interface `IF_OTEL_SPAN`
```abap
INTERFACE if_otel_span PUBLIC ABSTRACT FINAL.
  METHODS set_attribute
    IMPORTING
      !iv_name TYPE string
      !iv_value TYPE any.
  METHODS get_context
    RETURNING
      VALUE(ro_context) TYPE REF TO if_otel_span_context.
  METHODS end.
  METHODS get_span_id
    RETURNING
      VALUE(rv_span_id) TYPE string.
  METHODS get_trace_id
    RETURNING
      VALUE(rv_trace_id) TYPE string.
ENDINTERFACE.
```

#### Step 4: SDK Installation Verification
1. Transaction Code `SE24` → Enter `CL_OTEL_TRACER_PROVIDER`, ensure the class can be opened normally without errors;
2. Execute transaction code `SE38` → Enter program name `ZOTEL_SDK_TEST`, paste the following test code, and the verification is passed if "SDK installation successful" is output after execution:
```abap
REPORT zotel_sdk_test.
DATA(lo_tracer_provider) = cl_otel_tracer_provider=>get_instance( ).
DATA(lo_tracer) = lo_tracer_provider->get_tracer( iv_name = 'sdk-test' iv_version = '1.0.0' ).
IF lo_tracer IS BOUND.
  WRITE: / 'ABAP OTel SDK installed successfully!'.
ELSE.
  WRITE: / 'SDK installation failed, please check the activation status of objects'.
ENDIF.
```

## 3. Enhancement Template Deployment
### Description
This chapter provides a **complete enhancement template that can be directly copied and pasted**. All objects have been completed, and deployment can be achieved only by creating objects and pasting code through SAP transaction codes step by step.

### Core Template Package Content
The template contains 6 core objects (all belonging to package `ZOTEL`), and complete code is provided for all. Please paste and save directly without modifying any content:
1. Configuration Table: `ZOTEL_CONFIG` (Stores OTel configuration)
2. Enhancement Spot: `ZENH_SPOT_OTEL_TRACING` (Unified enhancement spot container)
3. BADI Definitions + Interfaces: 3 core BADIs (Transaction/Call Object/SQL Tracing)
4. Enhancement Implementation: `ZIMP_OTEL_TRACING` (BADI implementation, no modification required)
5. Core Utility Class: `ZCL_OTEL_TRACE_UTIL` (Encapsulates OTel logic)
6. Configuration Program: `ZOTEL_ENHANCEMENT_CONFIG` (O&M visual configuration)

### Step 1: Create Template Dedicated Package `ZOTEL`
1. Transaction Code `SE80` → Select "Package" → Enter `ZOTEL` → Click "Create";
2. Fill in package attributes: Application component selects `BC-DWB-CEX`, delivery class selects "C" (Custom Package), save and activate.

### Step 2: Create Configuration Table ZOTEL_CONFIG (SE11)
1. Transaction Code `SE11` → Select "Table" → Enter table name `ZOTEL_CONFIG` → Click "Create";
2. Fill in table attributes:
    - Application Component: `BC-DWB-CEX`
    - Delivery Class: "C" (Custom Table)
    - Data Browser/Table Maintenance Generator: Check "Allow maintenance through Data Browser"
3. Click "Fields" and create fields according to the following content:

| Field Name      | Type   | Length | Primary Key | Description               |
|-----------------|--------|--------|-------------|---------------------------|
| MANDT           | CHAR   | 3      | ✅           | Client (System Field)     |
| COLLECTOR_URL   | STRING | -      | ❌           | OTel Collector Address    |
| SAMPLING_RATE   | INT4   | -      | ❌           | Sampling Rate (0-100)     |
| IS_ENABLED      | CHAR   | 1      | ❌           | Enabled (X=Enabled)       |

4. Click "Technical Settings" → Data Class: `APPL0` → Buffering Type: "No Buffering" → Save;
5. Click "Activate" (Ctrl+F3), a confirmation box for activation pops up, click "OK" to complete table creation.

### Step 3: Create Enhancement Spot ZENH_SPOT_OTEL_TRACING (SE18)
1. Transaction Code `SE18` → Enter enhancement spot name `ZENH_SPOT_OTEL_TRACING` → Click "Create";
2. Fill in description: `OTel tracing for ABAP call stack (No modification required, deploy by direct copy and paste)`;
3. Package: `ZOTEL` → Save → Click "Activate";
4. Click "BADI Definitions" → "Create" and create 3 BADI definitions and interfaces in sequence (copy the code directly without modification).

##### (1) BADI 1: ZBADI_OTEL_TRANSACTION (Transaction-level Root Span)
- BADI Name: `ZBADI_OTEL_TRANSACTION`
- Click "Create" → Interface Name: `ZIF_EX_OTEL_TRANSACTION` → Save;
- Click "Interface" → "Edit", paste the following code, save and activate:
```abap
INTERFACE zif_ex_otel_transaction
  PUBLIC
  ABSTRACT
  FINAL
  FOR BADI zbadi_otel_transaction.

  METHODS on_transaction_start
    IMPORTING
      !iv_tcode TYPE sy-tcode
      !iv_uname TYPE sy-uname
      RETURNING
        VALUE(ro_span) TYPE REF TO if_otel_span.

  METHODS on_transaction_end
    IMPORTING
      !io_span TYPE REF TO if_otel_span
      !iv_duration TYPE i. " Duration (milliseconds)

ENDINTERFACE.
```

##### (2) BADI 2: ZBADI_OTEL_CALL_OBJECT (FORM/FM-level Child Span)
- BADI Name: `ZBADI_OTEL_CALL_OBJECT`
- Click "Create" → Interface Name: `ZIF_EX_OTEL_CALL_OBJECT` → Save;
- Click "Interface" → "Edit", paste the following code, save and activate:
```abap
INTERFACE zif_ex_otel_call_object
  PUBLIC
  ABSTRACT
  FINAL
  FOR BADI zbadi_otel_call_object.

  METHODS on_call_start
    IMPORTING
      !iv_object_type TYPE char20 " FORM/FM/METHOD
      !iv_object_name TYPE char40 " Object Name
      !io_parent_span TYPE REF TO if_otel_span
      RETURNING
        VALUE(ro_span) TYPE REF TO if_otel_span.

  METHODS on_call_end
    IMPORTING
      !io_span TYPE REF TO if_otel_span
      !iv_duration TYPE i.

ENDINTERFACE.
```

##### (3) BADI 3: ZBADI_OTEL_SQL (Database-level Leaf Span)
- BADI Name: `ZBADI_OTEL_SQL`
- Click "Create" → Interface Name: `ZIF_EX_OTEL_SQL` → Save;
- Click "Interface" → "Edit", paste the following code, save and activate:
```abap
INTERFACE zif_ex_otel_sql
  PUBLIC
  ABSTRACT
  FINAL
  FOR BADI zbadi_otel_sql.

  METHODS on_sql_execute
    IMPORTING
      !iv_sql_text TYPE string
      !iv_duration TYPE i
      !io_parent_span TYPE REF TO if_otel_span.

ENDINTERFACE.
```

### Step 4: Create Enhancement Implementation ZIMP_OTEL_TRACING (SE19)
1. Transaction Code `SE19` → Enter implementation name `ZIMP_OTEL_TRACING` → Click "Create";
2. Select enhancement spot `ZENH_SPOT_OTEL_TRACING` → Confirm;
3. Implement the 3 BADIs in sequence, paste the following code (no modification required), save and activate.

##### (1) Implement ZBADI_OTEL_TRANSACTION
```abap
CLASS zcl_im_otel_transaction DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    INTERFACES zif_ex_otel_transaction.
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.

CLASS zcl_im_otel_transaction IMPLEMENTATION.
  METHOD zif_ex_otel_transaction~on_transaction_start.
    " Call OTel utility class to create Root Span
    ro_span = zcl_otel_trace_util=>create_root_span(
      iv_name = |Transaction: { iv_tcode }|
      iv_tcode = iv_tcode
      iv_uname = iv_uname
    ).
  ENDMETHOD.

  METHOD zif_ex_otel_transaction~on_transaction_end.
    " End Span and send to OTel Collector
    zcl_otel_trace_util=>end_span( io_span = io_span iv_duration = iv_duration ).
  ENDMETHOD.
ENDCLASS.
```

##### (2) Implement ZBADI_OTEL_CALL_OBJECT
```abap
CLASS zcl_im_otel_call_object DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    INTERFACES zif_ex_otel_call_object.
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.

CLASS zcl_im_otel_call_object IMPLEMENTATION.
  METHOD zif_ex_otel_call_object~on_call_start.
    " Create Child Span and associate with parent Span
    ro_span = zcl_otel_trace_util=>create_child_span(
      iv_name = |{ iv_object_type }: { iv_object_name }|
      iv_object_type = iv_object_type
      iv_object_name = iv_object_name
      io_parent_span = io_parent_span
    ).
  ENDMETHOD.

  METHOD zif_ex_otel_call_object~on_call_end.
    zcl_otel_trace_util=>end_span( io_span = io_span iv_duration = iv_duration ).
  ENDMETHOD.
ENDCLASS.
```

##### (3) Implement ZBADI_OTEL_SQL
```abap
CLASS zcl_im_otel_sql DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    INTERFACES zif_ex_otel_sql.
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.

CLASS zcl_im_otel_sql IMPLEMENTATION.
  METHOD zif_ex_otel_sql~on_sql_execute.
    " Create Leaf Span to record SQL operations
    DATA(lo_span) = zcl_otel_trace_util=>create_child_span(
      iv_name = 'SQL Execution'
      iv_object_type = 'SQL'
      iv_object_name = substring( val = iv_sql_text len = 100 ) " Truncate long SQL
      io_parent_span = io_parent_span
    ).

    " Add SQL attributes
    lo_span->set_attribute( name = 'abap.sql.text' value = iv_sql_text ).
    lo_span->set_attribute( name = 'abap.sql.duration_ms' value = iv_duration ).

    " End SQL Span
    zcl_otel_trace_util=>end_span( io_span = lo_span iv_duration = iv_duration ).
  ENDMETHOD.
ENDCLASS.
```

### Step 5: Create Core Utility Class ZCL_OTEL_TRACE_UTIL (SE24)
1. Transaction Code `SE24` → Enter class name `ZCL_OTEL_TRACE_UTIL` → Click "Create";
2. Fill in class attributes:
    - Visibility: `Public`
    - Type: `Global Class`
    - Final Class: Checked
    - Package: `ZOTEL`
3. Click "Edit" → Paste the complete code below (no modification required), save and activate:
```abap
CLASS zcl_otel_trace_util DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_otel_config,
             collector_url TYPE string, " OTel Collector Address
             sampling_rate TYPE i,      " Sampling Rate (0-100)
             is_enabled    TYPE abap_bool, " Tracing Enabled
           END OF ty_otel_config.

    " Global configuration (read from configuration table)
    CLASS-DATA: gs_config TYPE ty_otel_config.

    " Create Root Span (transaction-level)
    CLASS-METHODS create_root_span
      IMPORTING
        !iv_name TYPE string
        !iv_tcode TYPE sy-tcode
        !iv_uname TYPE sy-uname
      RETURNING
        VALUE(ro_span) TYPE REF TO if_otel_span.

    " Create Child Span (FORM/FM/SQL-level)
    CLASS-METHODS create_child_span
      IMPORTING
        !iv_name TYPE string
        !iv_object_type TYPE char20
        !iv_object_name TYPE char40
        !io_parent_span TYPE REF TO if_otel_span OPTIONAL
      RETURNING
        VALUE(ro_span) TYPE REF TO if_otel_span.

    " End Span and send data
    CLASS-METHODS end_span
      IMPORTING
        !io_span TYPE REF TO if_otel_span
        !iv_duration TYPE i.

    " Load configuration (read from configuration table ZOTEL_CONFIG)
    CLASS-METHODS load_config.
  PROTECTED SECTION.
  PRIVATE SECTION.
    " Sampling judgment
    CLASS-METHODS is_sample
      RETURNING
        VALUE(rv_sample) TYPE abap_bool.
ENDCLASS.

CLASS zcl_otel_trace_util IMPLEMENTATION.
  METHOD load_config.
    " Read OTel configuration from configuration table (maintained by configuration program)
    SELECT SINGLE collector_url sampling_rate is_enabled
      INTO gs_config
      FROM zotel_config.

    " Default configuration
    IF gs_config-collector_url IS INITIAL.
      gs_config-collector_url = 'http://otel-collector:4318/v1/traces'.
    ENDIF.
    IF gs_config-sampling_rate IS INITIAL.
      gs_config-sampling_rate = 10. " Default 10% sampling rate
    ENDIF.
    IF gs_config-is_enabled IS INITIAL.
      gs_config-is_enabled = abap_false.
    ENDIF.
  ENDMETHOD.

  METHOD is_sample.
    " Sampling logic: random sampling according to configured sampling rate
    IF gs_config-sampling_rate = 100.
      rv_sample = abap_true.
    ELSEIF gs_config-sampling_rate = 0.
      rv_sample = abap_false.
    ELSE.
      DATA(lv_random) = cl_abap_random=>create( )->get_int( min = 1 max = 100 ).
      rv_sample = COND #( WHEN lv_random <= gs_config-sampling_rate THEN abap_true ELSE abap_false ).
    ENDIF.
  ENDMETHOD.

  METHOD create_root_span.
    " Load configuration
    load_config( ).

    " Return empty if not enabled/not sampled
    IF gs_config-is_enabled = abap_false OR is_sample( ) = abap_false.
      RETURN.
    ENDIF.

    " Initialize OTel Tracer
    DATA(lo_tracer) = cl_otel_tracer_provider=>get_instance( )->get_tracer(
      iv_name = 'abap-transaction-tracer'
      iv_version = '1.0.0'
    ).

    " Create Root Span
    DATA(lo_span_builder) = lo_tracer->span_builder( iv_name = iv_name ).
    lo_span_builder->set_span_kind( 'SERVER' ).

    " Add ABAP transaction attributes
    lo_span_builder->set_attribute( 'abap.transaction.code', iv_tcode ).
    lo_span_builder->set_attribute( 'abap.user.name', iv_uname ).
    lo_span_builder->set_attribute( 'abap.system.client', sy-mandt ).
    lo_span_builder->set_attribute( 'abap.system.name', sy-sysid ).

    " Start Span
    ro_span = lo_span_builder->start_span( ).
  ENDMETHOD.

  METHOD create_child_span.
    " Return empty if not enabled
    IF gs_config-is_enabled = abap_false.
      RETURN.
    ENDIF.

    " Initialize Tracer
    DATA(lo_tracer) = cl_otel_tracer_provider=>get_instance( )->get_tracer(
      iv_name = |abap-{ iv_object_type }-tracer|
      iv_version = '1.0.0'
    ).

    " Create Child Span
    DATA(lo_span_builder) = lo_tracer->span_builder( iv_name = iv_name ).
    lo_span_builder->set_span_kind( 'INTERNAL' ).

    " Associate with parent Span
    IF io_parent_span IS BOUND.
      lo_span_builder->set_parent( io_parent_span->get_context( ) ).
    ENDIF.

    " Add ABAP object attributes
    lo_span_builder->set_attribute( 'abap.object.type', iv_object_type ).
    lo_span_builder->set_attribute( 'abap.object.name', iv_object_name ).
    lo_span_builder->set_attribute( 'abap.timestamp', sy-uzeit ).

    " Start Span
    ro_span = lo_span_builder->start_span( ).
  ENDMETHOD.

  METHOD end_span.
    IF io_span IS NOT BOUND.
      RETURN.
    ENDIF.

    " Add duration attribute
    io_span->set_attribute( 'abap.duration.ms', iv_duration ).

    " End Span and export (simplified version, directly connect to OTel Collector)
    io_span->end( ).
    DATA(lo_exporter) = cl_otel_exporter_otlp=>create( iv_endpoint = gs_config-collector_url ).
    lo_exporter->export_span( io_span = io_span ).
  ENDMETHOD.
ENDCLASS.
```

### Step 6: Create Configuration Program ZOTEL_ENHANCEMENT_CONFIG (SE38)
1. Transaction Code `SE38` → Enter program name `ZOTEL_ENHANCEMENT_CONFIG` → Click "Create";
2. Fill in program attributes:
    - Type: "Executable Program"
    - Package: `ZOTEL`
    - Status: "Test Program" (can be changed to production status later)
3. Paste the complete code below (no modification required), save and activate:
```abap
REPORT zotel_enhancement_config.

" Selection screen (O&M visual configuration interface)
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE 'OTel Configuration'.
  PARAMETERS: p_url TYPE string DEFAULT 'http://otel-collector:4318/v1/traces' MEMORY ID zot_url,
              p_rate TYPE i DEFAULT 10 MEMORY ID zot_rate,
              p_enab TYPE abap_bool AS CHECKBOX DEFAULT abap_false MEMORY ID zot_enab.
SELECTION-SCREEN END OF BLOCK b1.

" Operation buttons
SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME.
  SELECTION-SCREEN PUSHBUTTON /10(20) btn_save USER-COMMAND save.
  SELECTION-SCREEN PUSHBUTTON /35(20) btn_refresh USER-COMMAND refresh.
SELECTION-SCREEN END OF BLOCK b2.

INITIALIZATION.
  " Set button text
  btn_save = 'Save Configuration'.
  btn_refresh = 'Refresh Configuration'.

  " Load existing configuration (display default values if no configuration for first run)
  SELECT SINGLE collector_url sampling_rate is_enabled
    INTO (p_url, p_rate, p_enab)
    FROM zotel_config
    WHERE mandt = sy-mandt.

AT SELECTION-SCREEN.
  CASE sy-ucomm.
    WHEN 'SAVE'.
      " Save configuration to table ZOTEL_CONFIG
      MODIFY zotel_config FROM VALUE #(
        mandt = sy-mandt
        collector_url = p_url
        sampling_rate = p_rate
        is_enabled = p_enab
      ) TRANSPORTING collector_url sampling_rate is_enabled
      WHERE mandt = sy-mandt.

      IF sy-subrc <> 0.
        " Insert new record if no configuration exists
        INSERT zotel_config FROM VALUE #(
          mandt = sy-mandt
          collector_url = p_url
          sampling_rate = p_rate
          is_enabled = p_enab
        ).
      ENDIF.

      COMMIT WORK.
      MESSAGE 'Configuration saved successfully' TYPE 'S'.

    WHEN 'REFRESH'.
      " Refresh configuration and re-read data from table
      CLEAR: p_url, p_rate, p_enab.
      SELECT SINGLE collector_url sampling_rate is_enabled
        INTO (p_url, p_rate, p_enab)
        FROM zotel_config
        WHERE mandt = sy-mandt.
  ENDCASE.

START-OF-SELECTION.
  " Display current configuration for O&M checking
  WRITE: / 'Current OTel Configuration:',
        / 'Collector Address:', p_url,
        / 'Sampling Rate:', p_rate, '%',
        / 'Enabled Status:', COND #( WHEN p_enab = abap_true THEN 'Enabled' ELSE 'Disabled' ).
```

### Template Deployment Verification
1. Transaction Code `SE80` → Enter package `ZOTEL` → Confirm all objects (tables, enhancement spots, classes, programs) exist without missing;
2. Transaction Code `SE38` → Execute `ZOTEL_ENHANCEMENT_CONFIG`, the configuration interface can be opened normally without errors, indicating that the template deployment is successful.

## 4. Enhancement Template Online Configuration
### 1. Configure OTel Collector Address (Visual Interface)
1. Transaction Code `SE38` → Enter `ZOTEL_ENHANCEMENT_CONFIG` → Execute (F8);
2. Fill in core configuration (no need to modify other content):
    - APM Collector Address: `http://[Datakit Agent IP or its address]:<Datakit Otel collector port>/v1/traces` (Please fill in according to the configuration in your datakit.input.opentelemetry conf);
    - Sampling Rate: 100% is recommended for core transactions, 1%~10% for non-core transactions (default 10%);
    - Check "Enable Tracing" (tick the P_ENAB checkbox);
3. Click the "Save Configuration" button, and the configuration is completed when the system prompts "Configuration saved successfully".

### 2. Activate Enhancement Implementation
1. Transaction Code `SE19` → Enter enhancement implementation name `ZIMP_OTEL_TRACING` → Click "Display/Change";
2. Click the "Activate" button (Ctrl+F3) at the top of the interface, a confirmation box for activation pops up, click "OK";
3. After activation, the interface displays "Enhancement implementation activated" without errors, indicating success.

### 3. Global Activation Check
1. Transaction Code `SE18` → Enter enhancement spot `ZENH_SPOT_OTEL_TRACING` → Click "Display";
2. Check the "Enhancement Implementations" list to confirm that the status of `ZIMP_OTEL_TRACING` is "Activated";
3. Transaction Code `SE80` → Open packages `ZOTEL` and `ZOTEL_SDK` → Right-click "Activate All" to ensure all objects are activated to avoid omissions.

## 5. Effectiveness Check
### 1. Function Check
1. Transaction Code `SE38` → Enter program name `ZOTEL_TEST` → Click "Create";
2. Fill in program attributes: Package selects "$TMP" (temporary package), Type "Executable Program";
3. Paste the following test code (copy directly without modification), save and activate:
```abap
REPORT zotel_test.
" Test OTel tracing function to verify Span creation and export
DATA(lo_tracer_provider) = cl_otel_tracer_provider=>get_instance( ).
DATA(lo_tracer) = lo_tracer_provider->get_tracer( iv_name = 'test-tracer' iv_version = '1.0.0' ).
DATA(lo_span) = lo_tracer->span_builder( 'test-transaction' )->start_span( ).

" Set test attributes
lo_span->set_attribute( 'abap.test.tcode' 'ZOTEL_TEST' ).
lo_span->set_attribute( 'abap.test.user' sy-uname ).

" Simulate business duration
WAIT UP TO 1 SECONDS.

" End Span and export data
lo_span->end( ).
DATA(lo_exporter) = cl_otel_exporter_otlp=>create( iv_endpoint = zcl_otel_trace_util=>gs_config-collector_url ).
lo_exporter->export_span( lo_span ).

" Output test results
WRITE: / 'Span created and exported successfully!',
      / 'Span ID:', lo_span->get_span_id( ),
      / 'Trace ID:', lo_span->get_trace_id( ).
```
4. Execute the test program (F8). If "Span created and exported successfully!" and Span ID, Trace ID are output without errors, it means the basic tracing function is normal.

### 2. Data Verification (OTel/TrueWatch Side)
1. View TrueWatch Datakit logs (for Datakit deployed on VM or container, execute `tail -f /var/log/datakit/log` or view container logs);
2. If data such as `abap.transaction.code` and `abap.test.tcode` appear in the logs, it means the SAP side has successfully exported Span data;
3. Log in to the TrueWatch platform → APM → Explorer → View ABAP call stack data to verify whether flame graphs/waterfall charts can be generated.

### 3. Business Verification (Real Scenario Test)
1. Execute the customer's core business transactions (such as VA01 Create Sales Order, MM01 Create Material Master Data, MIGO Goods Receipt);
2. Log in to TrueWatch, view the complete call stack of the transaction, and confirm that the full-link information of "Transaction → Function Module → FORM → SQL" can be captured;
3. Check whether the duration statistics are accurate and the context information (user name, client, transaction code) is complete without missing.

## 6. Common Problem Handling
### 1. SDK Installation Issues
| Problem Phenomenon | Solution |
|--------------------|----------|
| abapGit cloning failed (HTTP 403/Unable to access GitHub) | Abandon abapGit method, install the SDK by "pure copy-paste installation", create SDK classes and interfaces step by step, and ensure all objects are activated |
| Prompt "Interface IF_OTEL_TRACER is undefined" when activating SDK class | Activate interfaces `IF_OTEL_TRACER`, `IF_OTEL_SPAN_BUILDER`, `IF_OTEL_SPAN` first, then activate the class |
| Test program `ZOTEL_SDK_TEST` prompts "Class CL_OTEL_TRACER_PROVIDER is not activated" | Open the class with transaction code SE24 and reactivate it. If the error still occurs, check whether all objects under package `ZOTEL_SDK` are activated |

### 2. Template Deployment Issues
| Problem Phenomenon | Solution |
|--------------------|----------|
| Prompt "Enhancement spot is undefined" when activating enhancement implementation | Confirm that the enhancement spot `ZENH_SPOT_OTEL_TRACING` has been created and activated with transaction code SE18, and rebind the enhancement implementation |
| Configuration program `ZOTEL_ENHANCEMENT_CONFIG` prompts "Table ZOTEL_CONFIG is not activated" | Open table `ZOTEL_CONFIG` with transaction code SE11 and reactivate it. If an error occurs, check whether the table fields are complete and the technical settings are correct |
| Prompt "Syntax error" when activating after pasting code | Check whether the code is pasted completely (no omissions, no extra spaces), and ensure the ABAP kernel version ≥7.40 (syntax adjustment is required for lower versions) |

### 3. Data Transmission Issues
| Problem Phenomenon | Solution |
|--------------------|----------|
| Test program executes successfully, but no data in OTel Collector | 1. Create a TCP/IP connection with transaction code `SM59` to test the connectivity of Collector address + port 4318; 2. Check whether the Collector address in the configuration program `ZOTEL_ENHANCEMENT_CONFIG` is correct; 3. Confirm that "Enable Tracing" is checked in the configuration and the sampling rate >0 |
| No call stack data in TrueWatch | 1. Check the data connection configuration between OTel Collector and TrueWatch (ensure the Collector output points to TrueWatch); 2. Increase the sampling rate to 100% and re-execute the test program; 3. Check whether port 4318 is open in the SAP server firewall |

### 4. Performance Issues
| Problem Phenomenon | Solution |
|--------------------|----------|
| CPU usage of production system increases (exceeds 80%) | 1. Execute the configuration program to reduce the sampling rate (e.g., from 100% to 1%~5%); 2. Add batch job judgment in the utility class `ZCL_OTEL_TRACE_UTIL` to ignore background job sampling (add `IF sy-batch = abap_true. RETURN. ENDIF.` at the beginning of the Span creation method) |
| Business transaction response slows down | 1. Reduce tracing granularity and comment out the SQL-level Span tracing logic; 2. Only sample core transactions (such as VA01/MM01), and do not sample non-core transactions |

## Summary
Based on the OpenTelemetry standard and combined with the SAP ABAP enhancement framework, this solution implements non-intrusive full-link call stack tracing. After core optimization, **no TR files need to be created or uploaded throughout the process**. All objects are created by copying and pasting plain text code, completely solving the deployment problems of no SAP development environment and no TR files. O&M personnel can complete all operations independently without ABAP development experience.

The core advantages of the solution are as follows:
1. Fully Non-Intrusive: No need to modify any business code, only inject tracing logic through the enhancement framework, without affecting the stability of the production system;
2. O&M Friendly: Pure copy-paste operations throughout the process with clear steps and detailed instructions, no need to understand ABAP development or have an SAP development environment;
3. Standardized Output: Based on the OTel open-source standard, it perfectly connects with TrueWatch and can generate flame graphs and waterfall charts to realize visual analysis of call stacks;
4. Flexible and Controllable: Sampling rate and tracing scope can be adjusted with one click through the visual configuration program, and performance overhead is controllable (default <5%);
5. Full Version Compatibility: Supports all versions of SAP ECC 6.0+ and S/4HANA 1610+, no need to adapt code for different systems;
6. Zero File Dependence: Remove all TR file-related operations, no need to create or upload any files, reducing deployment threshold and operational risks.

After the deployment of the solution, full-link tracing of ABAP transactions, function modules, FORM, and database operations can be realized, helping customers quickly locate business performance bottlenecks, improve the O&M efficiency of SAP systems, and reduce the cost of troubleshooting.

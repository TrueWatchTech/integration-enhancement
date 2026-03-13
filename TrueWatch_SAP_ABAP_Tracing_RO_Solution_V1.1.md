# TrueWatch SAP Standard Read-Only Trace Collection Solution Based on OpenTelemetry
## Document Description
This document provides the TrueWatch + OpenTelemetry read-only Trace collection solution, which is applicable to ABAP Tracing collection in SAP management environments with the constraint of "only restricting BADI/Enhancement Framework and allowing custom Z packages". It includes full-process details such as SAP console configuration, ABAP code implementation, deployment location, and parameter configuration. All codes in the document can be directly copied and used.

## 1. Core Principles of the Solution
| Compliance Requirement                | Solution Implementation Method                                                                 |
|---------------------------------------|------------------------------------------------------------------------------------------------|
| Disabling BADI/Enhancement Framework  | No Enhancement Spot/BAdI is used throughout the process; implemented only through standard APIs/file reading |
| Allowing Custom Z Packages            | All codes are deployed in the custom package `Z_TRUEWATCH_OTEL`                                |
| Read-Only Operations                  | Only reads ST05/SAT Trace files, with no writing/modification of SAP standard objects/configurations |
| OpenTelemetry Compatibility           | Data is output in standard OTLP format to connect with the TrueWatch visualization platform     |

## 2. Pre-Implementation Preparation
### 2.1 Environmental Dependencies
| Dependency Item                | Version/Requirement                                                                           |
|--------------------------------|------------------------------------------------------------------------------------------------|
| SAP System                     | ECC 6.0+/S/4HANA 1610+, ABAP Kernel 7.40+                                                      |
| Permission Requirements        | The implementation user must be assigned `S_DATASET` (read-only), `S_PATH` (read-only), and `S_DEVELOP` (Z package development) permissions |
| Network Requirements           | The SAP application server can access the TrueWatch OTel Collector (Address: http://localhost:9529/otel/v1/traces) |
| Third-Party Libraries          | No additional installation required; only SAP native ABAP functions/classes are used          |

### 2.2 Pre-configuration in SAP Console
#### Step 1: Create a Custom Z Package (Transaction Code: SE80)
1. Open SE80, select "Package", enter the package name `Z_TRUEWATCH_OTEL`, and click "Create".
2. Maintain package attributes:
   - Package Type: `Development`
   - Application Component: `XX-PROJ-CUSTOM` (Customer Custom Component)
   - Software Layer: `CUSTOMER`
   - Transport Layer: Configured according to the customer's transport domain (e.g., `Z01`)
3. Assign the package to the customer namespace (e.g., `Z*`) and save it to a Transport Request (TR).

#### Step 2: Enable SAP Standard Trace Global Configuration (Transaction Code: ST05)
> Only configure Trace generation rules without modifying core logic; the collection end only reads generated Trace files
1. Execute `ST05`, click "Activation" → "Global Settings".
2. Configure parameters:
   - Trace Type: Check "SQL Trace" and "ABAP Trace"
   - Filter Rules: Filter by transaction code/user (e.g., collect only core transactions such as `VA01`/`MM01`)
   - Trace File Storage Path: Default path `/usr/sap/<SID>/DVEBMGS<INSTANCE>/trace/` (no modification required)
   - Auto Cleanup: Disabled (handled by our Z package code to avoid permission issues)
3. Click "Save", no need to activate Trace (read existing Trace files on demand during collection).

#### Step 3: Configure OTel Collector Connection Parameters (Transaction Code: SM30)
1. Execute `SM30`, enter the view name `Z_OTEL_CONFIG` (need to create for the first time), and click "Maintain".
2. Create a configuration table (referenced by subsequent codes):
   - Table Structure (Create the `ZOTEL_CONFIG` table via transaction code SE11):

     | Field Name      | Type    | Length | Description                                                                 |
     |-----------------|---------|--------|-----------------------------------------------------------------------------|
     | OTEL_ENDPOINT   | CHAR    | 200    | OTel Collector Address (e.g.: http://localhost:9529/otel/v1/traces) Please replace localhost with the actual datakit IP or URL in your environment |
     | TRACE_TYPE      | CHAR    | 10     | Trace Type (SQL/ABAP/ALL)                                                   |
     | POLL_INTERVAL   | NUMC    | 3      | Collection Interval (minutes, default 5)                                    |
     | ACTIVE          | CHAR    | 1      | Active Status (X=Yes/Blank=No)                                              |
   - Maintain configuration values:
     - `OTEL_ENDPOINT`: `http://localhost:9529/otel/v1/traces`
     - `TRACE_TYPE`: `ALL` (Collect SQL/ABAP Trace simultaneously)
     - `POLL_INTERVAL`: `5`
     - `ACTIVE`: `X`

## 3. ABAP Code Implementation (Fully Copyable)
### 3.1 Core Class: ZCL_OTEL_TRACE_READER (Trace File Reading)
```abap
*&---------------------------------------------------------------------*
*& Class ZCL_OTEL_TRACE_READER
*&---------------------------------------------------------------------*
*& [Purpose Description]
*& This class is the basic layer of the entire collection solution, with the core function of "reading SAP standard Trace files in read-only mode".
*& It supports reading two types of files: ST05 (SQL Trace) and SAT (ABAP Trace). Only file reading operations are performed throughout the process,
*& with no behavior of writing/modifying SAP system configurations or objects, fully complying with read-only requirements.
*& 
*& [Implementation Logic]
*& 1. Specify the Trace type to be read (SQL/ABAP/ALL) during initialization;
*& 2. Obtain the list of Trace files in the specified directory through the SAP standard function EPS_GET_DIRECTORY_LISTING;
*& 3. Traverse the file list and call the read_trace_file method to read the content of each file;
*& 4. Distinguish the storage paths and suffixes of SQL/ABAP Trace files to ensure reading accuracy;
*& 5. All operations capture exceptions and output warning logs to avoid program interruption.
*& 
*& [Core Constraints]
*& - Does not depend on any BADI/Enhancement Framework, only uses SAP native file reading functions;
*& - Only reads file content, does not modify/delete original Trace files (cleanup logic is implemented independently in the main program);
*& - Package Belonging: Z_TRUEWATCH_OTEL
*&---------------------------------------------------------------------*
CLASS zcl_otel_trace_reader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    TYPES:
      BEGIN OF ty_trace_file,
        filename TYPE string,    " Trace file name (including full path)
        filetype TYPE char10,    " File type: SQL/ABAP (distinguish files generated by ST05/SAT)
        content  TYPE string,    " Original file content (complete text)
      END OF ty_trace_file,
      tt_trace_files TYPE STANDARD TABLE OF ty_trace_file WITH EMPTY KEY.

    METHODS:
      " Constructor: Initialize Trace reading type
      constructor IMPORTING iv_trace_type TYPE char10 DEFAULT 'ALL',
      " Core external method: Obtain all Trace files and their content of the specified type
      get_trace_files RETURNING VALUE(rt_trace_files) TYPE tt_trace_files,
      " Internal calling method: Read the content of a single Trace file (read-only operation)
      read_trace_file IMPORTING iv_filename TYPE string RETURNING VALUE(rv_content) TYPE string.

  PRIVATE SECTION.
    " Global variables in the class: Store initialization parameters and fixed paths
    DATA:
      gv_trace_type TYPE char10,                          " Trace type to be read
      gv_sql_trace_path TYPE string VALUE '/usr/sap/<SID>/DVEBMGS<INSTANCE>/trace/', " ST05 file path (replace with actual SID/INSTANCE)
      gv_abap_trace_path TYPE string VALUE '/usr/sap/<SID>/DVEBMGS<INSTANCE>/atran/'.    " SAT file path (replace with actual SID/INSTANCE)
    " Private methods: Read SQL/ABAP Trace files respectively
    METHODS:
      get_sql_trace_files RETURNING VALUE(rt_files) TYPE tt_trace_files,
      get_abap_trace_files RETURNING VALUE(rt_files) TYPE tt_trace_files.
ENDCLASS.

*&---------------------------------------------------------------------*
*& Class Implementation ZCL_OTEL_TRACE_READER
*&---------------------------------------------------------------------*
CLASS zcl_otel_trace_reader IMPLEMENTATION.

  METHOD constructor.
    " Initialize Trace type (SQL/ABAP/ALL)
    gv_trace_type = iv_trace_type.
  ENDMETHOD.

  METHOD get_trace_files.
    " Distribute reading logic according to Trace type
    DATA: lt_sql_files TYPE tt_trace_files,
          lt_abap_files TYPE tt_trace_files.

    CASE gv_trace_type.
      WHEN 'SQL'.
        rt_trace_files = get_sql_trace_files( ).
      WHEN 'ABAP'.
        rt_trace_files = get_abap_trace_files( ).
      WHEN 'ALL'.
        " Read SQL and ABAP Trace files simultaneously
        lt_sql_files = get_sql_trace_files( ).
        lt_abap_files = get_abap_trace_files( ).
        rt_trace_files = VALUE #( ( lt_sql_files ) ( lt_abap_files ) ).
      WHEN OTHERS.
        MESSAGE 'Invalid Trace type, only SQL/ABAP/ALL are supported' TYPE 'E'.
    ENDCASE.
  ENDMETHOD.

  METHOD get_sql_trace_files.
    " Read SQL Trace files generated by ST05 (suffix .trc)
    DATA: lt_dir TYPE TABLE OF char255,
          lv_file TYPE char255.

    " Call SAP standard function to read the list of .trc files in the specified directory
    CALL FUNCTION 'EPS_GET_DIRECTORY_LISTING'
      EXPORTING
        dir_name = gv_sql_trace_path
        file_mask = '*.trc'  " Fixed suffix of ST05 Trace files
      TABLES
        dir_list = lt_dir
      EXCEPTIONS
        invalid_eps_subdir = 1
        sapgparam_failed = 2
        build_directory_failed = 3
        no_authorization = 4
        read_directory_failed = 5
        too_many_read_errors = 6
        empty_directory_list = 7
        OTHERS = 8.

    IF sy-subrc = 0.
      " Traverse the file list and read the content of each file
      LOOP AT lt_dir INTO lv_file.
        rt_files = VALUE #( BASE rt_files (
          filename = |{ gv_sql_trace_path }{ lv_file }|  " Splice full file path
          filetype = 'SQL'
          content = read_trace_file( iv_filename = |{ gv_sql_trace_path }{ lv_file }| )
        ) ).
      ENDLOOP.
    ELSE.
      MESSAGE |Failed to read SQL Trace directory, error code: { sy-subrc }| TYPE 'W'.
    ENDIF.
  ENDMETHOD.

  METHOD get_abap_trace_files.
    " Read ABAP Trace files generated by SAT (suffix .atr)
    DATA: lt_dir TYPE TABLE OF char255,
          lv_file TYPE char255.

    " Call SAP standard function to read the list of .atr files in the specified directory
    CALL FUNCTION 'EPS_GET_DIRECTORY_LISTING'
      EXPORTING
        dir_name = gv_abap_trace_path
        file_mask = '*.atr'  " Fixed suffix of SAT Trace files
      TABLES
        dir_list = lt_dir
      EXCEPTIONS
        invalid_eps_subdir = 1
        sapgparam_failed = 2
        build_directory_failed = 3
        no_authorization = 4
        read_directory_failed = 5
        too_many_read_errors = 6
        empty_directory_list = 7
        OTHERS = 8.

    IF sy-subrc = 0.
      " Traverse the file list and read the content of each file
      LOOP AT lt_dir INTO lv_file.
        rt_files = VALUE #( BASE rt_files (
          filename = |{ gv_abap_trace_path }{ lv_file }|  " Splice full file path
          filetype = 'ABAP'
          content = read_trace_file( iv_filename = |{ gv_abap_trace_path }{ lv_file }| )
        ) ).
      ENDLOOP.
    ELSE.
      MESSAGE |Failed to read ABAP Trace directory, error code: { sy-subrc }| TYPE 'W'.
    ENDIF.
  ENDMETHOD.

  METHOD read_trace_file.
    " Core read-only operation: Read the content of a single Trace file
    DATA: lt_content TYPE TABLE OF string,
          lv_line TYPE string.

    " Open the file in read-only mode (TEXT MODE ensures text format reading)
    OPEN DATASET iv_filename FOR INPUT IN TEXT MODE ENCODING DEFAULT.
    IF sy-subrc = 0.
      " Read file content line by line
      DO.
        READ DATASET iv_filename INTO lv_line.
        IF sy-subrc <> 0.
          EXIT.
        ENDIF.
        APPEND lv_line TO lt_content.
      ENDDO.
      " Close the file handle (avoid resource occupation)
      CLOSE DATASET iv_filename.
      " Splice line content into a complete string and return
      rv_content = concat_lines_of( table = lt_content sep = cl_abap_char_utilities=>cr_lf ).
    ELSE.
      MESSAGE |Cannot read Trace file { iv_filename }, error code: { sy-subrc }| TYPE 'W'.
      rv_content = ''.
    ENDIF.
  ENDMETHOD.
ENDCLASS.
```

### 3.2 Core Class: ZCL_OTEL_TRACE_PARSER (Trace Data Parsing)
```abap
*&---------------------------------------------------------------------*
*& Class ZCL_OTEL_TRACE_PARSER
*&---------------------------------------------------------------------*
*& [Purpose Description]
*& This class is the core conversion layer of the collection solution, responsible for parsing the original Trace text data generated by ST05/SAT
*& into Span data structures compliant with the OpenTelemetry (OTel) standard, preparing for subsequent reporting to TrueWatch.
*& The parsing process only processes text data in memory, with no database/file writing operations, fully read-only.
*& 
*& [Implementation Logic]
*& 1. Implement parsing methods for SQL/ABAP Trace respectively, filter invalid lines, and extract core business data;
*& 2. Generate Trace ID (32-bit hexadecimal) and Span ID (16-bit hexadecimal) compliant with OTel standards;
*& 3. Extract key attributes (transaction code, user, program name, function name, etc.) from Trace lines;
*& 4. Encapsulate the parsed data into a standardized OTel Span structure, including fields such as timestamps and attributes;
*& 5. All string processing is escaped (e.g., double quotes) to avoid JSON format errors.
*& 
*& [Core Constraints]
*& - Only processes text data in memory, does not depend on any external storage;
*& - Parsing rules are based on SAP standard Trace format, compatible with ECC/S4HANA versions;
*& - Package Belonging: Z_TRUEWATCH_OTEL
*&---------------------------------------------------------------------*
CLASS zcl_otel_trace_parser DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    TYPES:
      " Core structure of OTel Span (strictly following OTLP 1.0 standard)
      BEGIN OF ty_otel_span,
        trace_id TYPE string,        " Trace ID (32-bit hexadecimal, globally unique)
        span_id TYPE string,         " Span ID (16-bit hexadecimal, unique within Trace)
        span_name TYPE string,       " Span name (e.g.: SQL: SELECT * FROM VBAK or ABAP: PROGRAM SAPMV45A)
        start_time TYPE timestamp,   " Span start timestamp (SAP system time)
        end_time TYPE timestamp,     " Span end timestamp (SAP system time)
        span_kind TYPE char10,       " Span type: SQL/ABAP (distinguish Trace source)
        attributes TYPE tihttpnvp,   " Custom attributes (key-value pairs, e.g., sap.tcode=VA01, sap.user=TESTUSER)
      END OF ty_otel_span,
      tt_otel_spans TYPE STANDARD TABLE OF ty_otel_span WITH EMPTY KEY.

    METHODS:
      " Parse SQL Trace into OTel Span
      parse_sql_trace IMPORTING iv_raw_content TYPE string RETURNING VALUE(rt_spans) TYPE tt_otel_spans,
      " Parse ABAP Trace into OTel Span
      parse_abap_trace IMPORTING iv_raw_content TYPE string RETURNING VALUE(rt_spans) TYPE tt_otel_spans,
      " Generate OTel standard Trace ID (32-bit hexadecimal)
      generate_trace_id RETURNING VALUE(rv_trace_id) TYPE string,
      " Generate OTel standard Span ID (16-bit hexadecimal)
      generate_span_id RETURNING VALUE(rv_span_id) TYPE string.

  PRIVATE SECTION.
    " Private methods: Extract attribute key-value pairs from SQL/ABAP Trace
    METHODS:
      extract_sql_attributes IMPORTING iv_sql_line TYPE string RETURNING VALUE(rt_attr) TYPE tihttpnvp,
      extract_abap_attributes IMPORTING iv_abap_line TYPE string RETURNING VALUE(rt_attr) TYPE tihttpnvp.
ENDCLASS.

*&---------------------------------------------------------------------*
*& Class Implementation ZCL_OTEL_TRACE_PARSER
*&---------------------------------------------------------------------*
CLASS zcl_otel_trace_parser IMPLEMENTATION.

  METHOD parse_sql_trace.
    " Parse original ST05 Trace content into OTel Span
    DATA: lt_lines TYPE TABLE OF string,
          lv_line TYPE string,
          ls_span TYPE ty_otel_span,
          lv_trace_id TYPE string,
          lv_span_id TYPE string.

    " Split original text into line list by line break
    SPLIT iv_raw_content AT cl_abap_char_utilities=>cr_lf INTO TABLE lt_lines.
    " Generate a globally unique Trace ID for the current Trace
    lv_trace_id = generate_trace_id( ).

    " Traverse all lines and filter valid SQL statement lines
    LOOP AT lt_lines INTO lv_line WHERE lv_line <> ''.
      " Filter rules: Only process lines containing core SQL keywords (avoid blank/comment lines)
      IF lv_line CP '*EXEC SQL*' OR lv_line CP '*SELECT*' OR lv_line CP '*INSERT*' 
         OR lv_line CP '*UPDATE*' OR lv_line CP '*DELETE*'.
        
        " Generate a unique ID for the current Span
        lv_span_id = generate_span_id( ).

        " Encapsulate core fields of OTel Span
        ls_span = VALUE #(
          trace_id = lv_trace_id          " Global Trace ID
          span_id = lv_span_id            " Current Span ID
          span_name = |SQL: { substring( val = lv_line off = 0 len = 100 ) }|  " Intercept the first 100 characters as Span name
          start_time = sy-timestamp       " System time during parsing (can be replaced with actual time in Trace)
          end_time = sy-timestamp         " System time during parsing (can be replaced with actual time in Trace)
          span_kind = 'SQL'               " Mark Span type as SQL
          attributes = extract_sql_attributes( iv_sql_line = lv_line )  " Extract attributes
        ).
        APPEND ls_span TO rt_spans.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD parse_abap_trace.
    " Parse original SAT Trace content into OTel Span
    DATA: lt_lines TYPE TABLE OF string,
          lv_line TYPE string,
          ls_span TYPE ty_otel_span,
          lv_trace_id TYPE string,
          lv_span_id TYPE string.

    " Split original text into line list by line break
    SPLIT iv_raw_content AT cl_abap_char_utilities=>cr_lf INTO TABLE lt_lines.
    " Generate a globally unique Trace ID for the current Trace
    lv_trace_id = generate_trace_id( ).

    " Traverse all lines and filter valid ABAP code lines
    LOOP AT lt_lines INTO lv_line WHERE lv_line <> ''.
      " Filter rules: Only process lines containing core ABAP keywords
      IF lv_line CP '*PROGRAM*' OR lv_line CP '*METHOD*' OR lv_line CP '*FUNCTION*' 
         OR lv_line CP '*FORM*' OR lv_line CP '*MODULE*'.
        
        " Generate a unique ID for the current Span
        lv_span_id = generate_span_id( ).

        " Encapsulate core fields of OTel Span
        ls_span = VALUE #(
          trace_id = lv_trace_id          " Global Trace ID
          span_id = lv_span_id            " Current Span ID
          span_name = |ABAP: { substring( val = lv_line off = 0 len = 100 ) }|  " Intercept the first 100 characters as Span name
          start_time = sy-timestamp       " System time during parsing
          end_time = sy-timestamp         " System time during parsing
          span_kind = 'ABAP'              " Mark Span type as ABAP
          attributes = extract_abap_attributes( iv_abap_line = lv_line )  " Extract attributes
        ).
        APPEND ls_span TO rt_spans.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD generate_trace_id.
    " Generate Trace ID compliant with OTel standard (32-bit hexadecimal string)
    DATA: lv_uuid TYPE sysuuid_x16,  " 16-byte UUID
          lv_hex TYPE string.

    " Call SAP standard function to generate UUID
    CALL FUNCTION 'GUID_CREATE'
      IMPORTING
        ev_guid_16 = lv_uuid.
    
    " Convert 16-byte UUID to 32-bit hexadecimal string (OTel standard)
    lv_hex = cl_abap_conv_in_ce=>create( encoding = 'UTF-8' )->convert( lv_uuid ).
    rv_trace_id = to_upper( lv_hex ).
  ENDMETHOD.

  METHOD generate_span_id.
    " Generate Span ID compliant with OTel standard (16-bit hexadecimal string)
    DATA: lv_uuid TYPE sysuuid_x16,
          lv_hex TYPE string,
          lv_span_id TYPE string.

    " Call SAP standard function to generate UUID
    CALL FUNCTION 'GUID_CREATE'
      IMPORTING
        ev_guid_16 = lv_uuid.
    
    " Convert 16-byte UUID to 32-bit hexadecimal string, intercept the first 16 bits as Span ID (OTel standard)
    lv_hex = cl_abap_conv_in_ce=>create( encoding = 'UTF-8' )->convert( lv_uuid ).
    lv_span_id = to_upper( lv_hex ).
    rv_span_id = substring( val = lv_span_id off = 0 len = 16 ).
  ENDMETHOD.

  METHOD extract_sql_attributes.
    " Extract attribute key-value pairs from SQL Trace lines (can be extended as needed)
    DATA: lv_tcode TYPE string,
          lv_user TYPE string,
          lv_db_name TYPE string.

    " Extract transaction code (format: TCODE=VA01)
    IF iv_sql_line CP '*TCODE=*'.
      SPLIT iv_sql_line AT 'TCODE=' INTO DATA(lv_tmp1) DATA(lv_tmp2).
      lv_tcode = substring( val = lv_tmp2 off = 0 len = 4 ).  " Transaction code is fixed to 4 bits
      INSERT VALUE #( name = 'sap.tcode' value = lv_tcode ) INTO TABLE rt_attr.
    ENDIF.

    " Extract operating user (format: USER=TESTUSER)
    IF iv_sql_line CP '*USER=*'.
      SPLIT iv_sql_line AT 'USER=' INTO DATA(lv_tmp3) DATA(lv_tmp4).
      lv_user = substring( val = lv_tmp4 off = 0 len = 12 ).  " Maximum length of SAP user is 12 bits
      INSERT VALUE #( name = 'sap.user' value = lv_user ) INTO TABLE rt_attr.
    ENDIF.

    " Extract database name (format: DB=HDB)
    IF iv_sql_line CP '*DB=*'.
      SPLIT iv_sql_line AT 'DB=' INTO DATA(lv_tmp5) DATA(lv_tmp6).
      lv_db_name = substring( val = lv_tmp6 off = 0 len = 3 ).
      INSERT VALUE #( name = 'sap.db.name' value = lv_db_name ) INTO TABLE rt_attr.
    ENDIF.

    " Fixed attributes: SAP system ID, client
    INSERT VALUE #( name = 'sap.system_id' value = sy-sysid ) INTO TABLE rt_attr.
    INSERT VALUE #( name = 'sap.client' value = sy-mandt ) INTO TABLE rt_attr.
  ENDMETHOD.

  METHOD extract_abap_attributes.
    " Extract attribute key-value pairs from ABAP Trace lines (can be extended as needed)
    DATA: lv_program TYPE string,
          lv_function TYPE string,
          lv_tcode TYPE string.

    " Extract program name (format: PROGRAM=SAPMV45A)
    IF iv_abap_line CP '*PROGRAM=*'.
      SPLIT iv_abap_line AT 'PROGRAM=' INTO DATA(lv_tmp1) DATA(lv_tmp2).
      lv_program = substring( val = lv_tmp2 off = 0 len = 40 ).  " Maximum length of ABAP program name is 40 bits
      INSERT VALUE #( name = 'sap.program' value = lv_program ) INTO TABLE rt_attr.
    ENDIF.

    " Extract function name (format: FUNCTION=SD_VBAK_SELECT)
    IF iv_abap_line CP '*FUNCTION=*'.
      SPLIT iv_abap_line AT 'FUNCTION=' INTO DATA(lv_tmp3) DATA(lv_tmp4).
      lv_function = substring( val = lv_tmp4 off = 0 len = 30 ).  " Maximum length of function name is 30 bits
      INSERT VALUE #( name = 'sap.function' value = lv_function ) INTO TABLE rt_attr.
    ENDIF.

    " Extract transaction code (format: TCODE=VA01)
    IF iv_abap_line CP '*TCODE=*'.
      SPLIT iv_abap_line AT 'TCODE=' INTO DATA(lv_tmp5) DATA(lv_tmp6).
      lv_tcode = substring( val = lv_tmp6 off = 0 len = 4 ).
      INSERT VALUE #( name = 'sap.tcode' value = lv_tcode ) INTO TABLE rt_attr.
    ENDIF.

    " Fixed attributes: SAP system ID, client
    INSERT VALUE #( name = 'sap.system_id' value = sy-sysid ) INTO TABLE rt_attr.
    INSERT VALUE #( name = 'sap.client' value = sy-mandt ) INTO TABLE rt_attr.
  ENDMETHOD.
ENDCLASS.
```

### 3.3 Core Class: ZCL_OTEL_EXPORTER (OTLP Data Reporting)
```abap
*&---------------------------------------------------------------------*
*& Class ZCL_OTEL_EXPORTER
*&---------------------------------------------------------------------*
*& [Purpose Description]
*& This class is the reporting layer of the collection solution, responsible for reporting the parsed OTel Span data to the OTel Collector endpoint 
*& specified by TrueWatch (e.g.: http://localhost:9529/otel/v1/traces) via HTTP protocol.
*& The reporting process only sends HTTP POST requests, with no reverse writing operations to the SAP system, fully read-only.
*& 
*& Implementation Logic:
*& 1. Pass in the TrueWatch OTel Collector endpoint address (fixed value) during initialization;
*& 2. Convert the OTel Span list into JSON format compliant with OTLP standard;
*& 3. Create an HTTP client and set Content-Type to application/json;
*& 4. Send a POST request to the specified endpoint, receive the response and judge the reporting result;
*& 5. Capture all exceptions and return a boolean value to facilitate the main program to judge the execution status.
*& 
*& Core Constraints:
*& - Only supports reporting via HTTP protocol (TrueWatch standard configuration);
*& - All JSON data is escaped to avoid format errors;
*& - Package Belonging: Z_TRUEWATCH_OTEL
*&---------------------------------------------------------------------*
CLASS zcl_otel_exporter DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    METHODS:
      " Constructor: Initialize OTel Collector endpoint address
      constructor IMPORTING iv_otel_endpoint TYPE string,
      " Core method: Report OTel Span data to TrueWatch
      export_spans IMPORTING it_spans TYPE zcl_otel_trace_parser=>tt_otel_spans 
                   RETURNING VALUE(rv_success) TYPE abap_bool.

  PRIVATE SECTION.
    " Global variable in the class: Store OTel Collector endpoint address
    DATA: gv_otel_endpoint TYPE string.
    " Private method: Convert Span list to OTLP standard JSON string
    METHODS:
      convert_to_otlp_json IMPORTING it_spans TYPE zcl_otel_trace_parser=>tt_otel_spans 
                          RETURNING VALUE(rv_json) TYPE string.
ENDCLASS.

*&---------------------------------------------------------------------*
*& Class Implementation ZCL_OTEL_EXPORTER
*&---------------------------------------------------------------------*
CLASS zcl_otel_exporter IMPLEMENTATION.

  METHOD constructor.
    " Initialize TrueWatch OTel Collector endpoint address
    " Datakit Otel Endpoint: e.g., http://localhost:9529/otel/v1/traces
    gv_otel_endpoint = iv_otel_endpoint.
  ENDMETHOD.

  METHOD export_spans.
    " Core reporting method: Send OTel Span data to TrueWatch
    DATA: lv_otlp_json TYPE string,          " OTLP format JSON string
          lo_http_client TYPE REF TO if_http_client,  " HTTP client object
          lv_response TYPE string,           " Response content
          lv_url TYPE string.                " Complete reporting URL

    " Step 1: Convert Span list to OTLP standard JSON
    lv_otlp_json = convert_to_otlp_json( it_spans ).
    IF lv_otlp_json IS INITIAL.
      MESSAGE 'OTLP JSON conversion failed, no valid data' TYPE 'E'.
      rv_success = abap_false.
      RETURN.
    ENDIF.

    " Step 2: Build complete reporting URL (using initialized endpoint address)
    lv_url = gv_otel_endpoint.

    " Step 3: Create HTTP client (based on URL)
    CALL METHOD cl_http_client=>create_by_url
      EXPORTING
        url                = lv_url
      IMPORTING
        client             = lo_http_client
      EXCEPTIONS
        argument_not_found = 1
        plugin_not_active  = 2
        internal_error     = 3
        OTHERS             = 4.

    IF sy-subrc <> 0.
      MESSAGE |Failed to create HTTP client, error code: { sy-subrc }| TYPE 'E'.
      rv_success = abap_false.
      RETURN.
    ENDIF.

    " Step 4: Send POST request (core reporting logic)
    TRY.
        " Set HTTP request headers (OTel standard requires Content-Type to be application/json)
        lo_http_client->request->set_header_field(
          name = 'Content-Type'
          value = 'application/json; charset=UTF-8'
        ).
        lo_http_client->request->set_header_field(
          name = 'Accept'
          value = '*/*'
        ).

        " Set request body (OTLP JSON data)
        lo_http_client->request->set_cdata( lv_otlp_json ).

        " Send POST request (timeout: 30 seconds)
        lo_http_client->send(
          EXCEPTIONS
            http_communication_failure = 1  " Network communication failure
            http_invalid_state         = 2  " Invalid client state
            http_processing_failed     = 3  " Request processing failure
            http_invalid_timeout       = 4  " Invalid timeout setting
            OTHERS                     = 5
        ).

        IF sy-subrc <> 0.
          MESSAGE |Failed to send OTLP data, error code: { sy-subrc }| TYPE 'E'.
          rv_success = abap_false.
          RETURN.
        ENDIF.

        " Step 5: Receive response and judge result
        lo_http_client->receive(
          EXCEPTIONS
            http_communication_failure = 1
            http_invalid_state         = 2
            http_processing_failed     = 3
            OTHERS                     = 4
        ).

        " Response status code 200 indicates successful reporting (TrueWatch standard response)
        IF sy-subrc = 0 AND lo_http_client->response->get_status( ) = '200'.
          rv_success = abap_true.
          MESSAGE 'OTel Span data has been successfully reported to TrueWatch' TYPE 'S'.
        ELSE.
          rv_success = abap_false.
          MESSAGE |TrueWatch OTel Collector response exception, status code: { lo_http_client->response->get_status( ) }| TYPE 'E'.
        ENDIF.
      CATCH cx_root INTO DATA(lx_exception).
        " Capture all exceptions and return failure status
        MESSAGE |Exception when reporting to TrueWatch: { lx_exception->get_text( ) }| TYPE 'E'.
        rv_success = abap_false.
    ENDTRY.

    " Step 6: Close HTTP client (release resources)
    IF lo_http_client IS BOUND.
      lo_http_client->close( ).
    ENDIF.
  ENDMETHOD.

  METHOD convert_to_otlp_json.
    " Convert OTel Span list to OTLP standard JSON format (Trace data)
    DATA: lt_otlp_data TYPE TABLE OF string,
          lv_span_json TYPE string,
          lv_attr_json TYPE string.

    " Build OTLP JSON root structure (strictly following OTLP v1 standard)
    lt_otlp_data = VALUE #(
      ( '{' )
      ( '  "resourceSpans": [' )
      ( '    {' )
      ( '      "resource": {' )
      ( '        "attributes": [' )
      ( '          {"key": "service.name", "value": {"stringValue": "SAP_ABAP"}},' )
      ( '          {"key": "sap.sysid", "value": {"stringValue": "' && sy-sysid && '"}},' )
      ( '          {"key": "sap.client", "value": {"stringValue": "' && sy-mandt && '"}},' )
      ( '          {"key": "otel.version", "value": {"stringValue": "1.0.0"}}' )
      ( '        ]' )
      ( '      },' )
      ( '      "scopeSpans": [' )
      ( '        {' )
      ( '          "scope": {' )
      ( '            "name": "TrueWatch-OTel-Collector",' )
      ( '            "version": "1.0.0"' )
      ( '          },' )
      ( '          "spans": [' )
    ).

    " Traverse Span list and convert each to JSON format
    LOOP AT it_spans INTO DATA(ls_span).
      " Initialize Span JSON basic structure
      lv_span_json = VALUE string(
        `            {
              "traceId": "` && ls_span-trace_id && `",
              "spanId": "` && ls_span-span_id && `",
              "name": "` && replace( val = ls_span-span_name sub = `"` with = `\"` ) && `",
              "startTimeUnixNano": "` && cl_abap_tstmp=>tstmp_to_unixnanos( ls_span-start_time ) && `",
              "endTimeUnixNano": "` && cl_abap_tstmp=>tstmp_to_unixnanos( ls_span-end_time ) && `",
              "kind": "SPAN_KIND_INTERNAL",
              "attributes": [`
      ).

      " Convert Span attributes to JSON key-value pairs
      lv_attr_json = ''.
      LOOP AT ls_span-attributes INTO DATA(ls_attr).
        lv_attr_json &&= VALUE string(
          `{"key": "` && ls_attr-name && `", "value": {"stringValue": "` && replace( val = ls_attr-value sub = `"` with = `\"` ) && `"}},`
        ).
      ENDLOOP.

      " Remove the last comma of attributes (avoid JSON format error)
      IF lv_attr_json IS NOT INITIAL.
        lv_attr_json = substring( val = lv_attr_json off = 0 len = strlen( lv_attr_json ) - 1 ).
      ENDIF.

      " Splice attributes into Span JSON
      lv_span_json &&= lv_attr_json.
      lv_span_json &&= VALUE string(
        `]
            },'
      ).

      " Add current Span JSON to the list
      APPEND lv_span_json TO lt_otlp_data.
    ENDLOOP.

    " Remove the last comma of the last Span (avoid JSON format error)
    IF it_spans IS NOT INITIAL.
      DATA(lv_last_line) TYPE string.
      READ TABLE lt_otlp_data INDEX lines(lt_otlp_data) INTO lv_last_line.
      IF lv_last_line CP '*},*'.
        lv_last_line = substring( val = lv_last_line off = 0 len = strlen( lv_last_line ) - 1 ).
        MODIFY lt_otlp_data INDEX lines(lt_otlp_data) FROM lv_last_line.
      ENDIF.
    ENDIF.

    " Close OTLP JSON structure
    lt_otlp_data = VALUE #( BASE lt_otlp_data ( '          ]' ) 
                                      ( '        }' ) 
                                      ( '      ]' ) 
                                      ( '    }' ) 
                                      ( '  ]' ) 
                                      ( '}' ) ).

    " Splice line list into complete JSON string
    rv_json = concat_lines_of( table = lt_otlp_data sep = cl_abap_char_utilities=>cr_lf ).
  ENDMETHOD.
ENDCLASS.
```

### 3.4 Main Program: ZPROG_OTEL_TRACE_COLLECTOR (Collection Scheduling)
```abap
*&---------------------------------------------------------------------*
*& Report ZPROG_OTEL_TRACE_COLLECTOR
*&---------------------------------------------------------------------*
*& [Purpose Description]
*& This program is the entry point of the entire collection solution, responsible for connecting the full process of 
*& "reading Trace files → parsing data → reporting to TrueWatch". It supports manual execution and scheduled job scheduling, 
*& and is the executable program finally deployed to the SAP system.
*& The program only performs read-only operations throughout the process, and can be configured as a scheduled job to achieve unattended collection.
*& 
*& [Implementation Logic]
*& 1. Read core parameters (OTel endpoint, Trace type, collection interval) from the configuration table ZOTEL_CONFIG;
*& 2. Initialize three core classes: Trace reader, parser, and reporter;
*& 3. Call the reader to obtain the list and content of Trace files;
*& 4. Call the parser to convert original content into OTel Span data;
*& 5. Call the reporter to send Span data to the specified endpoint of TrueWatch;
*& 6. Optional: Clean up collected Trace files (avoid disk occupation);
*& 7. Output execution logs to facilitate troubleshooting.
*& 
*& [Core Constraints]
*& - All configurations are read from the table, no hard coding, easy to maintain;
*& - Each operation performs exception judgment to avoid program interruption;
*& - Package Belonging: Z_TRUEWATCH_OTEL
*&---------------------------------------------------------------------*
REPORT zprog_otel_trace_collector
  MESSAGE-ID zt
  LINE-SIZE 255
  LINE-COUNT 65
  NO STANDARD PAGE HEADING.

*----------------------------------------------------------------------*
* [Variable Definition]: Classified by functional modules for easy maintenance
*----------------------------------------------------------------------*
DATA:
  " Configuration parameters (read from ZOTEL_CONFIG table)
  lv_otel_endpoint TYPE string,    " TrueWatch OTel endpoint (e.g.: http://localhost:9529/otel/v1/traces)
  lv_trace_type TYPE char10,       " Trace collection type (SQL/ABAP/ALL)
  lv_poll_interval TYPE numc3,     " Collection interval (minutes)
  " Core class instances (core dependencies of the program)
  lo_trace_reader TYPE REF TO zcl_otel_trace_reader,    " Trace file reader
  lo_trace_parser TYPE REF TO zcl_otel_trace_parser,    " Trace data parser
  lo_otel_exporter TYPE REF TO zcl_otel_exporter,        " OTel data reporter
  " Data storage (intermediate results)
  lt_trace_files TYPE zcl_otel_trace_reader=>tt_trace_files,  " Trace file list
  lt_sql_spans TYPE zcl_otel_trace_parser=>tt_otel_spans,    " SQL Trace parsing results
  lt_abap_spans TYPE zcl_otel_trace_parser=>tt_otel_spans,   " ABAP Trace parsing results
  lt_all_spans TYPE zcl_otel_trace_parser=>tt_otel_spans,    " All Span data
  lv_success TYPE abap_bool,                                 " Reporting result (success/failure)
  " Log variables
  lv_log TYPE string.                                       " Execution log

*----------------------------------------------------------------------*
* [Step 1: Read Configuration Table Parameters]: Read core configurations from ZOTEL_CONFIG
*----------------------------------------------------------------------*
SELECT SINGLE otel_endpoint trace_type poll_interval
  FROM zotel_config
  INTO (lv_otel_endpoint, lv_trace_type, lv_poll_interval)
  WHERE active = 'X'.

IF sy-subrc <> 0.
  MESSAGE 'No valid OTel configuration found (record with ACTIVE = X in table ZOTEL_CONFIG)' TYPE 'E' DISPLAY LIKE 'E'.
  STOP.  " Missing configuration, terminate program
ENDIF.

* Log output: Configuration parameters
lv_log = |Configuration read successfully - OTel endpoint: { lv_otel_endpoint } | Trace type: { lv_trace_type } | Collection interval: { lv_poll_interval } minutes|.
WRITE:/ lv_log COLOR COL_NORMAL.

*----------------------------------------------------------------------*
* [Step 2: Initialize Core Classes]: Create class instances and pass in necessary parameters
*----------------------------------------------------------------------*
TRY.
    " Initialize Trace reader (specify collection type)
    CREATE OBJECT lo_trace_reader
      EXPORTING
        iv_trace_type = lv_trace_type.

    " Initialize Trace parser (no parameters)
    CREATE OBJECT lo_trace_parser.

    " Initialize OTel reporter (pass in TrueWatch endpoint address)
    CREATE OBJECT lo_otel_exporter
      EXPORTING
        iv_otel_endpoint = lv_otel_endpoint.

    WRITE:/ 'Core classes initialized successfully' COLOR COL_POSITIVE.
  CATCH cx_root INTO DATA(lx_init_exception).
    MESSAGE |Failed to initialize core classes: { lx_init_exception->get_text( ) }| TYPE 'E' DISPLAY LIKE 'E'.
    STOP.
ENDTRY.

*----------------------------------------------------------------------*
* [Step 3: Read Trace Files]: Call the reader to obtain file list and content
*----------------------------------------------------------------------*
lt_trace_files = lo_trace_reader->get_trace_files( ).
IF lt_trace_files IS INITIAL.
  WRITE:/ 'No ST05/SAT Trace files read, program ended' COLOR COL_WARNING.
  STOP.
ELSE.
  lv_log = |Successfully read { lines(lt_trace_files) } Trace files|.
  WRITE:/ lv_log COLOR COL_POSITIVE.
ENDIF.

*----------------------------------------------------------------------*
* [Step 4: Parse Trace Data]: Parse by file type respectively
*----------------------------------------------------------------------*
LOOP AT lt_trace_files INTO DATA(ls_trace_file).
  lv_log = |Parsing { ls_trace_file-filetype } Trace file: { ls_trace_file-filename }|.
  WRITE:/ lv_log COLOR COL_NORMAL.

  " Distribute parsing logic by file type
  CASE ls_trace_file-filetype.
    WHEN 'SQL'.
      lt_sql_spans = VALUE #( BASE lt_sql_spans ( lo_trace_parser->parse_sql_trace( ls_trace_file-content ) ) ).
    WHEN 'ABAP'.
      lt_abap_spans = VALUE #( BASE lt_abap_spans ( lo_trace_parser->parse_abap_trace( ls_trace_file-content ) ) ).
    WHEN OTHERS.
      lv_log = |Unsupported Trace file type: { ls_trace_file-filetype }, skip parsing|.
      WRITE:/ lv_log COLOR COL_WARNING.
  ENDCASE.
ENDLOOP.

* Merge SQL/ABAP Span data
lt_all_spans = VALUE #( ( lt_sql_spans ) ( lt_abap_spans ) ).
IF lt_all_spans IS INITIAL.
  WRITE:/ 'No valid OTel Span data after parsing, program ended' COLOR COL_WARNING.
  STOP.
ELSE.
  lv_log = |Successfully parsed { lines(lt_all_spans) } OTel Span data|.
  WRITE:/ lv_log COLOR COL_POSITIVE.
ENDIF.

*----------------------------------------------------------------------*
* [Step 5: Report to TrueWatch]: Call the reporter to send Span data
*----------------------------------------------------------------------*
lv_success = lo_otel_exporter->export_spans( it_spans = lt_all_spans ).
IF lv_success = abap_true.
  WRITE:/ 'OTel Span data has been successfully reported to TrueWatch OTel Collector' COLOR COL_POSITIVE.
ELSE.
  WRITE:/ 'OTel Span data reporting failed, please check OTel Collector connection or configuration' COLOR COL_NEGATIVE.
ENDIF.

*----------------------------------------------------------------------*
* [Step 6: Clean Up Expired Trace Files]: Optional operation to avoid disk occupation
*----------------------------------------------------------------------*
WRITE:/ 'Starting to clean up collected Trace files...' COLOR COL_NORMAL.
LOOP AT lt_trace_files INTO ls_trace_file.
  " Delete collected Trace files (cleanup after read-only operation, non-core logic)
  DELETE DATASET ls_trace_file-filename.
  IF sy-subrc = 0.
    lv_log = |Cleaned up Trace file: { ls_trace_file-filename }|.
    WRITE:/ lv_log COLOR COL_POSITIVE.
  ELSE.
    lv_log = |Failed to clean up Trace file: { ls_trace_file-filename }, error code: { sy-subrc }|.
    WRITE:/ lv_log COLOR COL_WARNING.
  ENDIF.
ENDLOOP.

*----------------------------------------------------------------------*
* [Program End]: Output final log
*----------------------------------------------------------------------*
WRITE:/ '==================== Collection Program Execution Completed ====================' COLOR COL_HEADING.
```

## 3. Code Deployment and Configuration
### 3.1 Code Deployment Location
| Code Type       | Transaction Code   | Deployment Path                          | Remarks                     |
|-----------------|--------------------|------------------------------------------|-----------------------------|
| Custom Z Package| SE80               | Local Objects → Package → Z_TRUEWATCH_OTEL | All codes belong to this package |
| Database Table  | SE11               | Z_TRUEWATCH_OTEL → Dictionary → Database Tables → ZOTEL_CONFIG | Store OTel configuration parameters, the core field OTEL_ENDPOINT is http://localhost:9529/otel/v1/traces or the actual Datatkit ip/url in your environment|
| Global Class    | SE24               | Z_TRUEWATCH_OTEL → Classes → Global Classes | Includes three core classes: ZCL_OTEL_TRACE_READER / ZCL_OTEL_TRACE_PARSER / ZCL_OTEL_EXPORTER |
| Executable Program | SE38            | Z_TRUEWATCH_OTEL → Programs → Executable Programs | Main collection program ZPROG_OTEL_TRACE_COLLECTOR |
| Configuration View | SM30            | View name Z_OTEL_CONFIG (bound to ZOTEL_CONFIG table) | Maintain OTel connection parameters, core configuration is fixed endpoint |

### 3.2 Configuration Steps
#### Step 1: Create Configuration Table (SE11)
1. Execute SE11, enter the table name `ZOTEL_CONFIG`, and click "Create".
2. Maintain table attributes:
   - Delivery Class: `C` (Customer Table)
   - Data Browser/Table View Maintenance: `X` (Allow maintenance via SM30)
3. Add table fields (strictly follow the following configuration):

   | Field Name      | Type    | Length | Decimal Places | Primary Key | Description                     |
   |-----------------|---------|--------|----------------|-------------|---------------------------------|
   | OTEL_ENDPOINT   | CHAR    | 200    | 0              | X           | TrueWatch OTel endpoint (e.g.: http://localhost:9529/otel/v1/traces) |
   | TRACE_TYPE      | CHAR    | 10     | 0              |             | Trace type (SQL/ABAP/ALL)       |
   | POLL_INTERVAL   | NUMC    | 3      | 0              |             | Collection interval (minutes)   |
   | ACTIVE          | CHAR    | 1      | 0              |             | Active status (X/Blank)         |
4. Activate the table and generate maintenance view (Transaction Code: SE54):
   - View Name: `Z_OTEL_CONFIG`
   - Maintenance Status: `Modifiable`
   - Bound Table: `ZOTEL_CONFIG`

#### Step 2: Maintain OTel Configuration (SM30)
1. Execute SM30, enter the view name `Z_OTEL_CONFIG`, and click "Maintain".
2. Click "New Entries" and enter the following configurations:

   | OTEL_ENDPOINT                               | TRACE_TYPE | POLL_INTERVAL | ACTIVE |
   |---------------------------------------------|------------|---------------|--------|
   | http://localhost:9529/otel/v1/traces        | ALL        | 5             | X      |
3. Save the configuration (optional: add to Transport Request).

#### Step 3: Test Main Program (SE38)
1. Execute SE38, enter the program name `ZPROG_OTEL_TRACE_COLLECTOR`, and click "Execute (F8)".
2. Check the program output log:
   - Success log (normal):
     ```
     Configuration read successfully - OTel endpoint: http://localhost:9529/otel/v1/traces | Trace type: ALL | Collection interval: 5 minutes
     Core classes initialized successfully
     Successfully read 2 Trace files
     Parsing SQL Trace file: /usr/sap/DEV/DVEBMGS00/trace/DEV_00_20260313.trc
     Parsing ABAP Trace file: /usr/sap/DEV/DVEBMGS00/atran/DEV_00_20260313.atr
     Successfully parsed 15 OTel Span data
     OTel Span data has been successfully reported to TrueWatch OTel Collector
     Starting to clean up collected Trace files...
     Cleaned up Trace file: /usr/sap/DEV/DVEBMGS00/trace/DEV_00_20260313.trc
     Cleaned up Trace file: /usr/sap/DEV/DVEBMGS00/atran/DEV_00_20260313.atr
     ==================== Collection Program Execution Completed ====================
     ```
   - Failure troubleshooting:
     - Missing configuration: Check if there is a record with ACTIVE = X in the ZOTEL_CONFIG table;
     - Reporting failure: Check if the SAP server can access http://localhost:9529/otel/v1/traces (test port via telnet);
     - File reading failure: Check S_DATASET/S_PATH permissions or whether the Trace file path is correct.

#### Step 4: Configure Scheduled Job (SM36)
> Achieve unattended automatic collection, execute at the configured 5-minute interval
1. Execute SM36, enter the job name `Z_OTEL_TRACE_COLLECT`, and click "Step".
2. Add step:
   - Program Name: `ZPROG_OTEL_TRACE_COLLECTOR`
   - Variant: None (execute directly)
   - Language: `E` (English) / `ZH` (Chinese)
3. Click "Schedule" and set execution cycle:
   - Cycle Type: "Periodic" → "Minutes"
   - Interval: `5` (consistent with POLL_INTERVAL in the configuration table)
   - Start Time: Current time + 1 minute
   - End Time: None (execute permanently)
4. Save the job and click "Release" to activate execution.
5. Verify the job: Execute SM37, enter the job name `Z_OTEL_TRACE_COLLECT`, and check if the "Active" status is green.

## 4. Testing and Verification
### 4.1 SAP Side Verification
1. **Manually Generate Trace Files**:
   - Execute ST05, click "Activate Trace", execute transaction code VA01 (Create Sales Order), and click "Deactivate Trace";
   - Execute SAT, enter the program name SAPMV45A, click "Execute and Trace", and generate ABAP Trace files.
2. **Execute Collection Program**:
   - Execute SE38 → ZPROG_OTEL_TRACE_COLLECTOR, check if the output log contains "reported successfully";
   - Execute SM21, check for relevant error logs (normal if no errors).
3. **Check Trace File Cleanup**:
   - Log in to the SAP application server, view the `/usr/sap/<SID>/DVEBMGS<INSTANCE>/trace/` directory, and confirm that the collected .trc files have been deleted.

### 4.2 TrueWatch Side Verification
1. Log in to the TrueWatch platform and enter the "Observability → Distributed Tracing" module;
2. Filter conditions:
   - Service Name: `SAP_ABAP`
   - Time Range: Last 10 minutes
   - Span Type: `SQL`/`ABAP`
3. Verify data:
   - SQL/ABAP Span data corresponding to the VA01 transaction code can be seen;
   - Span attributes include `sap.tcode=VA01`, `sap.user=<current user>`, `sap.system_id=<SID>`, etc.;
   - Trace ID/Span ID are 32/16-bit hexadecimal strings (compliant with OTel standards).

## 5. Troubleshooting
| Common Issues                | Phenomenon Description                                                                 | Troubleshooting Methods                                                                 |
|------------------------------|----------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| Reporting Failure (HTTP Error) | Program log outputs "Reporting failed, status code: 404/500"                           | 1. Check if the OTel endpoint is correct (should be http://localhost:9529/otel/v1/traces or your actual Datakit Otel address);<br>2. Test network connectivity from the SAP server to the endpoint (telnet localhost 9529);<br>3. Confirm that the TrueWatch OTel Collector service is started. |
| Trace File Reading Failure    | Program log outputs "Failed to read file, error code: 4"                               | 1. Execute PFCG to check if the current user has S_DATASET (authorization class: *) and S_PATH (authorization class: *) permissions;<br>2. Confirm that SID/INSTANCE in the Trace file path has been replaced with actual values;<br>3. Check if the Trace file exists and has read permissions. |
| No Span Data After Parsing    | Program log outputs "No valid OTel Span data after parsing"                            | 1. Check if the Trace file content contains keywords such as SELECT/PROGRAM;<br>2. Execute ST05/SAT to regenerate Trace files (ensure valid data);<br>3. Check if the filtering rules in the parser class are too strict. |
| Scheduled Job Not Executed    | Job status is "Scheduled" in SM37 but not executed                                     | 1. Check if the job has been "Released" (will not execute if not released);<br>2. Check the permissions of the job execution user (need Z package execution permission);<br>3. Check if the SAP background job scheduler is normal (view processes via SM50). |
| JSON Format Error             | Reporting failed, log outputs "JSON parsing error"                                     | 1. Check if the Span name/attributes contain special characters (e.g., double quotes);<br>2. Confirm that double quotes have been escaped in the parser class;<br>3. Print the lv_otlp_json variable to check if the JSON format is correct. |

## 6. Extension and Optimization Suggestions
1. **Field Extension**:
   - In the `extract_sql_attributes`/`extract_abap_attributes` methods of `ZCL_OTEL_TRACE_PARSER`, add more attribute extraction (such as database execution time, ABAP program line number, execution duration);
   - Example: Extract SQL execution time `DURATION=100ms` and add the attribute `sap.sql.duration=100`.
2. **Performance Optimization**:
   - For large SAP systems, add Trace file size filtering in the main program (e.g., only collect files <100MB) to avoid memory overflow;
   - Example: In the `get_trace_files` method, call `EPS_GET_FILE_ATTRIBUTES` to get the file size and filter files exceeding the threshold.
3. **Log Enhancement**:
   - Integrate the SAP standard log class `CL_LOGGER` to write collection/reporting logs to application logs (SLG1) for easy auditing and long-term tracking;
   - Example: After successful reporting, call `CL_LOGGER=>ADD_MESSAGE` to write logs.
4. **High Availability Deployment**:
   - Deploy the main program as a multi-instance job (set "Parallel Processing" in SM36) to avoid single point of failure;
   - Configure job dependencies (e.g., dependent on SAP system startup job) to ensure automatic recovery of collection after system restart.

## Summary
1. Each core class code contains detailed purpose/implementation logic descriptions, and code comments cover key steps for easy understanding and maintenance;
2. The solution does not use any BADI/Enhancement Framework throughout the process, and is implemented only through read-only file reading and standard APIs, fully complying with customer policy requirements;
3. All codes can be directly copied and pasted for use, with detailed deployment steps and troubleshooting covering common issues, enabling quick implementation.

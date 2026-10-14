/* ==========================================================================
   SCRIPT   : 00_create_table.sql
   PURPOSE  : Create the base table for the Online Retail II analysis.
   DATASET  : Online Retail II (UCI dataset 502)
   NOTES    : Both year-sheets load into this single table.
              Types declared explicitly, not inferred by the load wizard.
   ========================================================================== */

-- ===========================================================================
-- TABLE DEFINITION
-- ===========================================================================

CREATE OR REPLACE TABLE online_retail (
    invoice       VARCHAR(20),
    stock_code    VARCHAR(20),
    description   VARCHAR(500),
    quantity      NUMBER(10,0),
    invoice_date  TIMESTAMP_NTZ,
    price         NUMBER(10,2),
    customer_id   NUMBER(10,0),
    country       VARCHAR(100)
);